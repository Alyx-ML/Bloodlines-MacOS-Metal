# Sourced by every build script after it sets HERE: one lock on native/build, so two
# builds at once (two sessions, say) take turns instead of linking each other's
# half-written objects. A script run by one that holds the lock (rebuild_all.sh running
# recompile_module.sh) shares it. A lock left by a build that no longer runs is taken over.
if [ -z "$BL_BUILD_LOCK_HELD" ]; then
    BL_LOCK="$HERE/build/.lock"
    mkdir -p "$HERE/build"
    bl_waited=0
    until mkdir "$BL_LOCK" 2>/dev/null; do
        bl_pid="$(cat "$BL_LOCK/pid" 2>/dev/null || true)"
        # Only "No such process" means gone: a sandbox may refuse to signal a live one.
        if [ -n "$bl_pid" ] && kill -0 "$bl_pid" 2>&1 | grep -q "No such process"; then
            echo "build lock: $(cat "$BL_LOCK/what" 2>/dev/null) (pid $bl_pid) is no longer running; taking its lock" >&2
            rm -rf "$BL_LOCK"
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
