# Sourced by every build script after it sets HERE: one lock on native/build, so two
# builds at once (two sessions, say) take turns instead of linking each other's
# half-written objects. A script run by one that holds the lock (rebuild_all.sh running
# recompile_module.sh) shares it. A lock left by a build that no longer runs is taken over:
# renamed away first, so of two builds that find it only one takes it. A lock without a
# process number (its build stopped between making it and writing the number) is left
# for 30 seconds, then taken over the same way.
if [ -z "$BL_BUILD_LOCK_HELD" ]; then
    BL_LOCK="$HERE/build/.lock"
    mkdir -p "$HERE/build"
    bl_waited=0
    until mkdir "$BL_LOCK" 2>/dev/null; do
        bl_pid="$(cat "$BL_LOCK/pid" 2>/dev/null || true)"
        bl_stale=0
        # Only "No such process" means gone: a sandbox may refuse to signal a live one.
        if [ -n "$bl_pid" ]; then
            kill -0 "$bl_pid" 2>&1 | grep -q "No such process" && bl_stale=1
        elif [ -d "$BL_LOCK" ] && [ $(( $(date +%s) - $(stat -f %m "$BL_LOCK" 2>/dev/null || date +%s) )) -gt 30 ]; then
            bl_stale=1
        fi
        if [ "$bl_stale" -eq 1 ]; then
            bl_old="$BL_LOCK.stale.$$"
            if mv "$BL_LOCK" "$bl_old" 2>/dev/null; then
                if [ "$(cat "$bl_old/pid" 2>/dev/null || true)" = "$bl_pid" ]; then
                    echo "build lock: $(cat "$bl_old/what" 2>/dev/null || echo 'a build') (pid ${bl_pid:-none}) is no longer running; taking its lock" >&2
                    rm -rf "$bl_old"
                elif [ ! -e "$BL_LOCK" ]; then
                    mv "$bl_old" "$BL_LOCK" 2>/dev/null  # a live build's new lock: given back
                fi
            fi
            continue
        fi
        if [ "$bl_waited" -eq 0 ]; then
            echo "build lock: waiting for $(cat "$BL_LOCK/what" 2>/dev/null || echo 'another build') (pid $bl_pid) to finish" >&2
            bl_waited=1
        fi
        sleep 2
    done
    echo $$ > "$BL_LOCK/pid"
    basename "$0" > "$BL_LOCK/what"
    trap 'rm -rf "$BL_LOCK"' EXIT
    trap 'exit 130' INT TERM HUP
    BL_BUILD_LOCK_HELD=1
    export BL_BUILD_LOCK_HELD
fi
