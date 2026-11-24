#!/usr/bin/env bash
# fm-exclude-tools-lib.sh - shared parsing and runtime-support checks for
# config/crew-exclude-tools, sourced by bin/fm-spawn.sh and bin/fm-control.sh.
#
# docs/configuration.md "Worker tool exclusions" owns the file format and
# operator contract, including the Codex worker home; bin/fm-spawn.sh's header
# owns launch-flag mechanics.
# Name verification belongs inside the worker's loaded-tool registry, never
# in an out-of-band server connection from these launch-time checks.

# Feature switches every Codex launch from the worker home carries, so the
# account's connectors and every plugin stay off whatever a config layer says.
FM_CODEX_WORKER_FLAGS='--disable apps --disable plugins --disable remote_plugin'

# fm_exclude_tools_names <config-dir>: print the comma-joined names, empty when
# the file is absent or lists nothing. Non-zero with the reason on stderr when
# the file or an entry is invalid.
fm_exclude_tools_names() {
  local config=$1 file line names='' present
  file=$config/crew-exclude-tools
  present=$(perl -MErrno=ENOENT -e '
    if (lstat $ARGV[0]) { print 1 }
    elsif ($! == ENOENT) { print 0 }
    else { die "error: cannot inspect config/crew-exclude-tools: $!\n" }
  ' -- "$file") || return 1
  [ "$present" = 1 ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/crew-exclude-tools must be a readable regular file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
    '' | '#'*) continue ;;
    esac
    if [ -n "${line//[A-Za-z0-9_.-]/}" ]; then
      echo "error: config/crew-exclude-tools has a malformed entry '$line'; expected one tool name per line using only letters, digits, _ . and - (blank lines and # comment lines are allowed)" >&2
      return 1
    fi
    names="${names:+$names,}$line"
  done <"$file" || {
    echo "error: cannot read config/crew-exclude-tools" >&2
    return 1
  }
  printf '%s' "$names"
}

# fm_codex_worker_home_present <config-dir>: print 1 when config/codex-worker-home
# exists in any form, 0 when absent; non-zero when the path cannot be inspected.
fm_codex_worker_home_present() {
  perl -MErrno=ENOENT -e '
    if (lstat $ARGV[0]) { print 1 }
    elsif ($! == ENOENT) { print 0 }
    else { die "error: cannot inspect config/codex-worker-home: $!\n" }
  ' -- "$1/codex-worker-home"
}

# fm_codex_worker_home_check <config-dir> <probe-dir>: prove that a Codex worker
# started from config/codex-worker-home in <probe-dir> has no connector, plugin,
# or MCP server configured, and print the home's absolute path. Refuses on
# anything it cannot prove: a missing or unreadable config.toml, a config line
# naming one of those tool sources, a failed or unparsable readback, or any
# enabled MCP server or connector/plugin feature in the installed codex's own
# effective view (which includes system, managed, and trusted-project layers).
fm_codex_worker_home_check() {
  local config=$1 probe=$2 home file out codex_bin
  local refuse="error: config/codex-worker-home cannot be proven free of connectors, plugins, and MCP servers, so this Codex launch is refused"
  home=$(cd "$config/codex-worker-home" 2>/dev/null && pwd -P) || {
    echo "$refuse: it is not a readable directory" >&2
    return 1
  }
  file=$home/config.toml
  if [ -L "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "$refuse: $file must be a readable regular file" >&2
    return 1
  fi
  # Static pass over the worker home's own file: any table or key whose path
  # names a tool source, or a feature switch that is not plainly false, refuses
  # even though the launch also disables those features, so the worker home
  # itself never carries one. Multi-line strings cannot be tracked line by line
  # and refuse rather than risk hiding a table.
  out=$(perl -e '
    my %block = map { $_ => 1 } qw(mcp_servers plugins marketplaces apps connectors);
    my %feature = map { $_ => 1 } qw(apps plugins remote_plugin);
    my ($table, $n) = ("", 0);
    open my $fh, "<", $ARGV[0] or do { print "cannot read the file\n"; exit 1 };
    while (my $raw = <$fh>) {
      $n++;
      my $line = $raw;
      $line =~ s/^\s+|\s+$//g;
      next if $line eq "" || $line =~ /^#/;
      if ($line =~ /"""|\x27\x27\x27/) { print "line $n opens a multi-line string\n"; exit 1 }
      my $path;
      if ($line =~ /^\[\[?\s*([^\]]+?)\s*\]\]?/) {
        ($table = $1) =~ s/["\x27\s]//g;
        $path = $table;
      } elsif ($line =~ /^([^=]+?)\s*=\s*(.*)$/) {
        my ($key, $value) = ($1, $2);
        $key =~ s/["\x27\s]//g;
        $path = $table eq "" ? $key : "$table.$key";
        my @seg = split /\./, $path;
        if ($seg[0] eq "features") {
          if (@seg == 1) { print "line $n sets features inline\n"; exit 1 }
          if ($feature{$seg[1]} && $value !~ /^false\s*(#.*)?$/) { print "line $n does not set features.$seg[1] to false\n"; exit 1 }
        }
      } else {
        next;
      }
      my $first = (split /\./, $path)[0];
      if ($block{$first}) { print "line $n configures $path\n"; exit 1 }
    }
    exit 0
  ' -- "$file") || {
    echo "$refuse: $file ${out:-could not be scanned}" >&2
    return 1
  }
  codex_bin=$(command -v codex) || {
    echo "$refuse: the codex executable is not on PATH to read its effective configuration" >&2
    return 1
  }
  if [ -z "$probe" ] || [ ! -d "$probe" ]; then
    echo "$refuse: the launch directory '${probe:-none}' is missing" >&2
    return 1
  fi
  # Effective readback through the installed codex, from the launch directory
  # and with the launch's own feature switches.
  # shellcheck disable=SC2086  # FM_CODEX_WORKER_FLAGS is a fixed word list.
  out=$(cd "$probe" && CODEX_HOME=$home "$codex_bin" mcp list --json $FM_CODEX_WORKER_FLAGS 2>/dev/null) || {
    echo "$refuse: codex mcp list failed" >&2
    return 1
  }
  out=$(printf '%s' "$out" | perl -MJSON::PP -e '
    my $d = eval { decode_json(do { local $/; <STDIN> }) };
    if (ref $d ne "ARRAY") { print "unparsable codex mcp list output\n"; exit 1 }
    my @on = map { ref $_ eq "HASH" ? ($_->{name} // "?") : "?" }
      grep { !(ref $_ eq "HASH" && exists $_->{enabled} && !$_->{enabled}) } @$d;
    if (@on) { print "enabled MCP servers: ", join(", ", @on), "\n"; exit 1 }
    exit 0
  ') || {
    echo "$refuse: ${out:-codex mcp list could not be checked}" >&2
    return 1
  }
  # shellcheck disable=SC2086  # FM_CODEX_WORKER_FLAGS is a fixed word list.
  out=$(cd "$probe" && CODEX_HOME=$home "$codex_bin" features list $FM_CODEX_WORKER_FLAGS 2>/dev/null) || {
    echo "$refuse: codex features list failed" >&2
    return 1
  }
  out=$(printf '%s\n' "$out" | perl -e '
    my %want = map { $_ => 1 } qw(apps plugins remote_plugin);
    my %seen;
    while (<STDIN>) {
      my @f = split;
      next unless @f >= 2 && $want{$f[0]};
      if ($f[-1] ne "false") { print "codex reports feature $f[0] enabled\n"; exit 1 }
      $seen{$f[0]} = 1;
    }
    my @missing = grep { !$seen{$_} } sort keys %want;
    if (@missing) { print "codex features list did not report: @missing\n"; exit 1 }
    exit 0
  ') || {
    echo "$refuse: $out" >&2
    return 1
  }
  printf '%s' "$home"
}

# fm_codex_worker_home_resolve <config-dir> <probe-dir> <names>: print the
# proven worker home's absolute path for a Codex ship or scout launch, or
# nothing when config/codex-worker-home is absent and <names> is empty. Refuses
# when <names> is non-empty and no worker home exists.
fm_codex_worker_home_resolve() {
  local config=$1 probe=$2 names=$3 present
  present=$(fm_codex_worker_home_present "$config") || return 1
  if [ "$present" = 1 ]; then
    fm_codex_worker_home_check "$config" "$probe"
    return
  fi
  if [ -n "$names" ]; then
    echo "error: config/crew-exclude-tools lists tools to hide, but the codex runtime cannot hide tools, so this launch is refused rather than running with them available; create config/codex-worker-home (a Codex home with no connectors, plugins, or MCP servers), empty the file, or launch a runtime that supports exclusion (claude, pi, pi-signed)" >&2
    return 1
  fi
}

# fm_exclude_tools_check <harness> <raw-launch 0|1> <config-dir> [<probe-dir>]:
# succeed when this launch can honor the home's list (empty list, a runtime
# that hides tools, or codex with a proven config/codex-worker-home checked
# from <probe-dir>); otherwise refuse naming the file. Prints the names on
# stdout.
fm_exclude_tools_check() {
  local harness=$1 raw=$2 config=$3 probe=${4:-} names
  names=$(fm_exclude_tools_names "$config") || return 1
  if [ -n "$names" ]; then
    if [ "$raw" = 1 ]; then
      echo "error: config/crew-exclude-tools lists tools to hide, but a raw launch command cannot hide tools; remove the entries or launch a runtime that supports them (claude, pi, pi-signed, or codex with config/codex-worker-home)" >&2
      return 1
    fi
    case "$harness" in
    claude | pi | pi-signed) ;;
    codex) fm_codex_worker_home_resolve "$config" "$probe" "$names" >/dev/null || return 1 ;;
    *)
      echo "error: config/crew-exclude-tools lists tools to hide, but the $harness runtime cannot hide tools, so this launch is refused rather than running with them available; empty the file or launch a runtime that supports exclusion (claude, pi, pi-signed, or codex with config/codex-worker-home)" >&2
      return 1
      ;;
    esac
  fi
  printf '%s' "$names"
}
