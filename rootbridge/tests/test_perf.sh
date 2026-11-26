#!/usr/bin/env bash
# Test: rb_perf (rootbridge-lib.sh) measures cores, clock, memory, free space and the dot product from made-up /proc and
# /sys, and judges what suits the device (reading aloud, S1, Skejja); `rootbridge perf` shows it.
#   bash tests/test_perf.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$ROOT/tests/lib.sh"
make_tmp

# device <online cpus> <kHz per cpu ...> -- <MemTotal kB> <MemAvailable kB> <cpu features>: a made-up /proc and /sys
device() {
    rm -rf "$T/sys" "$T/proc"
    mkdir -p "$T/sys/devices/system/cpu" "$T/proc"
    printf '%s\n' "$1" > "$T/sys/devices/system/cpu/online"; shift
    local n=0
    while [ "$1" != -- ]; do
        mkdir -p "$T/sys/devices/system/cpu/cpu$n/cpufreq"
        printf '%s\n' "$1" > "$T/sys/devices/system/cpu/cpu$n/cpufreq/cpuinfo_max_freq"
        n=$((n + 1)); shift
    done
    shift
    printf 'MemTotal:       %s kB\nMemFree:        1000 kB\nMemAvailable:   %s kB\n' "$1" "$2" > "$T/proc/meminfo"
    printf 'processor\t: 0\nFeatures\t: %s\n' "$3" > "$T/proc/cpuinfo"
}
perf() {   # perf [score]: the output of rb_perf for the made-up device
    ( RB_SYS_DIR="$T/sys" RB_PROC_DIR="$T/proc" RB_PERF_SCORE="${1:-140}" PREFIX="$T"
      . "$ROOT/termux/lib/rootbridge-lib.sh"; rb_perf )
}
get() { sed -n "s/^$1=//p" <<< "$OUT"; }

# the Hisense A9: 8 cores (4 x 1.8 and 4 x 2.0 GHz), 6 GB, 2.3 GB available, no dot product
device 0-7 1804800 1804800 1804800 1804800 2016000 2016000 2016000 2016000 -- 6291456 2435216 "fp asimd aes crc32"
OUT="$(perf)"
check "A9: 8 Kerne, 2016 MHz"                   "8 2016" "$(get CORES) $(get MHZ)"
check "A9: 6144 MB, 2378 MB frei"               "6144 2378" "$(get MEM_MB) $(get FREE_MB)"
check "A9: kein Dot-Product"                    no "$(get DOTPROD)"
check "A9: Zusammenfassung"                     1 "$(get SUMMARY | grep -c '^8 Kerne bis 2,0 GHz, 6,0 GB RAM (2,3 GB frei), .* GB Platz, Rechentest 140$')"
check "A9: Vorlesen, S1, Skejja geeignet"       "yes yes yes" "$(get FIT_SPEAK) $(get FIT_S1) $(get FIT_SKEJJA)"
check "A9: Text geeignet"                       geeignet "$(get TEXT_SPEAK)"

# two cores, 700 MB available: reading aloud and S1 are tight, Skejja suits it; a dot product is seen
device 0-1 1200000 1200000 -- 2097152 716800 "fp asimd asimddp"
OUT="$(perf)"
check "Klein: 2 Kerne, Dot-Product"             "2 yes" "$(get CORES) $(get DOTPROD)"
check "Klein: Vorlesen und S1 knapp, Skejja geeignet" "tight tight yes" "$(get FIT_SPEAK) $(get FIT_S1) $(get FIT_SKEJJA)"
check "Klein: Grund nennt Kerne und Speicher"   "knapp: 2 Kerne (empfohlen 4), 0,6 GB RAM frei (empfohlen 1,0)" "$(get TEXT_SPEAK)"

# one core, 200 MB available, slow: nothing suits it
device 0 1000000 -- 1048576 204800 "fp"
OUT="$(perf 20)"
check "Schwach: nichts geeignet"                "no no no" "$(get FIT_SPEAK) $(get FIT_S1) $(get FIT_SKEJJA)"
check "Schwach: langsam im Grund"               1 "$(get TEXT_SPEAK | grep -c 'langsam (Rechentest 20, empfohlen 60)')"

# a slow device with enough of everything else: tight
device 0-3 1500000 -- 4194304 2097152 "fp"
OUT="$(perf 30)"
check "Langsam: Vorlesen knapp, Skejja geeignet" "tight yes" "$(get FIT_SPEAK) $(get FIT_SKEJJA)"

# nothing readable: no verdict against the device
rm -rf "$T/sys" "$T/proc"; mkdir -p "$T/sys" "$T/proc"
OUT="$( ( RB_SYS_DIR="$T/sys" RB_PROC_DIR="$T/proc" RB_PERF_SCORE=140 PREFIX="$T/missing"
          nproc() { return 1; }; . "$ROOT/termux/lib/rootbridge-lib.sh"; rb_perf ) )"
check "Nichts lesbar: kein Urteil dagegen"      "yes yes yes" "$(get FIT_SPEAK) $(get FIT_S1) $(get FIT_SKEJJA)"

# the count itself: a number when no score is given
OUT="$( ( RB_SYS_DIR="$T/sys" RB_PROC_DIR="$T/proc" PREFIX="$T"; unset RB_PERF_SCORE
          . "$ROOT/termux/lib/rootbridge-lib.sh"; rb_perf ) )"
check "Rechentest: eine Zahl"                   ja "$([[ "$(get SCORE)" =~ ^[0-9]+$ ]] && echo ja || echo nein)"

# rootbridge perf shows the summary and the verdicts
device 0-1 1200000 -- 2097152 716800 "fp"
out="$(RB_SYS_DIR="$T/sys" RB_PROC_DIR="$T/proc" RB_PERF_SCORE=140 PREFIX="$T" HOME="$T" \
       bash "$ROOT/termux/bin/rootbridge" perf 2>&1)"
check "rootbridge perf: Leistung"               1 "$(grep -c '^Leistung: *2 Kerne bis 1,2 GHz' <<< "$out")"
check "rootbridge perf: Vorlesen knapp"         1 "$(grep -c '^Vorlesen (Piper, Articulino): *knapp: 2 Kerne' <<< "$out")"
check "rootbridge perf: Skejja geeignet"        1 "$(grep -c '^Skejja (Sprachbefehle): *geeignet$' <<< "$out")"

echo
finish
