#!/bin/bash
args=()
for a in "$@"; do
    case "$a" in
        -Wl,*) ;;
        *) args+=("$a") ;;
    esac
done
exec clang "${args[@]}"
