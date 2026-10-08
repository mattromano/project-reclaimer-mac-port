#!/bin/zsh
# Launch Project Reclaimer under Wine.
#   RECLAIMER_GFX=wine (default): Wine Staging + DXVK-macOS (D3D11 -> Vulkan -> MoltenVK -> Metal)
#   RECLAIMER_GFX=metal:          CrossOver 24 Wine (Sikarugir build) + Apple D3DMetal (D3D11 -> Metal)
# Both share the game files and Workshop mods. Each Wine prefix keeps its own Documents folder (not ~/Documents),
# so each variant has its own Reclaimer profile and multi-GB mod downloads stay out of iCloud-synced folders.
BASE=${RECLAIMER_HOME:-~/Games/ProjectReclaimer}
GFX=${RECLAIMER_GFX:-wine}
MCC='C:\Program Files (x86)\Steam\steamapps\common\Halo The Master Chief Collection'
export WINEDEBUG=${WINEDEBUG:--all,err+d3d,err+vulkan,err+mmdevapi,err+coreaudio}

# Mesa opengl32.dll beside the exe: Reclaimer's menu needs OpenGL 3.0+, which Wine on macOS only gives core-profile apps
export GALLIUM_DRIVER=${GALLIUM_DRIVER:-llvmpipe}
# llvmpipe redraws the menu layer every frame; its worker threads each pin a core (menu idle ~440% CPU -> ~250%)
export LP_NUM_THREADS=${LP_NUM_THREADS:-0}
# xaudio2_9=d: MCC's xaudio2_9redist.dll forwards to the "inbox" xaudio2_9 on Windows 10, i.e. Wine's FAudio,
# which crashes mid-match and sounds poor; disabling it keeps Microsoft's own mixer
OVERRIDES="opengl32=n,b;xaudio2_9=d"

if [ "$GFX" = metal ]; then
  export WINEPREFIX="$BASE/prefix-metal"
  FW="$BASE/wine-metal/Wine Metal.app/Contents/Frameworks"
  WINE="$FW/wswine.bundle/bin/wine"
  # CrossOver 24 (Wine 9) rather than Apple's GPTK Wine 7.7: Reclaimer's networking (tokio) needs AFD socket polling,
  # which Wine 7.7 lacks ("Bad device type"), breaking the server browser and online play
  export DYLD_FALLBACK_LIBRARY_PATH="$FW:$FW/GStreamer.framework/Libraries:/usr/lib"
  # CrossOver's D3DMetal hook: Apple's d3d11/dxgi/d3d12 from the renderer folder, plus libd3dshared
  D3DM="$FW/renderer/d3dmetal"
  export WINEDLLPATH_PREPEND="$D3DM/wine" CX_D3DMETALPATH="$D3DM/external"
  export CX_APPLEGPTK_LIBD3DSHARED_PATH="$D3DM/external/libd3dshared.dylib"
  export WINEDLLOVERRIDES="$OVERRIDES;d3d11,d3d10core,dxgi,d3d12=b"
  export ROSETTA_ADVERTISE_AVX=1
else
  export WINEPREFIX="$BASE/prefix-wine"
  WINE="$BASE/wine/Wine Staging.app/Contents/Resources/wine/bin/wine"
  # DXVK-macOS d3d11/d3d10core in this prefix's system32 (Wine's own D3D11 cannot create a device on MoltenVK).
  # d3d11.dll there is spinfix, which forwards to DXVK (d3d11_dxvk.dll) and makes Halo 3's engine thread sleep instead
  # of spinning on the clock between frames: about one CPU core less. RECLAIMER_SPINFIX_US=0 turns it off.
  export WINEDLLOVERRIDES="$OVERRIDES;d3d11,d3d10core=n,b"
  export DXVK_ASYNC=1
  # DXVK logs every swapchain rebuild at info level, which bloats the log
  export DXVK_LOG_LEVEL=${DXVK_LOG_LEVEL:-warn}
  export MVK_CONFIG_LOG_LEVEL=1
fi
[ -n "$RECLAIMER_NO_AUDIO" ] && WINEDLLOVERRIDES="$WINEDLLOVERRIDES;winecoreaudio.drv=d"  # troubleshooting only

cd "$BASE/game" || exit 1
EXE=$(ls project-reclaimer-v*.exe 2>/dev/null | grep -v dedicated | sort -V | tail -1)
[ -n "$EXE" ] || { echo "Project Reclaimer is not installed in $BASE/game" >&2; exit 1; }
exec "$WINE" "$EXE" "${@:-game-client}" --mcc-path "$MCC"
