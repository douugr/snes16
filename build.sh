#!/bin/bash
# SNES16: emulador de Super Nintendo para iPad com iOS 8 (armv7).
# Core: Snes9x 2005 (libretro), compilado junto no app. Controle Bluetooth via BTstack.
#
# Uso:  ./build.sh            -> compila (build/SNES16.app)
#       ./build.sh install    -> compila e instala em /Applications do iPad (fora do sandbox, por causa do BTstack)
#       ./build.sh roms       -> envia as ROMs de ../roms para o iPad
#
# Variáveis: IPAD=192.168.1.105, X13=.../Xcode-13.4.1.app/Contents/Developer
set -euo pipefail
cd "$(dirname "$0")"

APP=SNES16
IPAD="${IPAD:-192.168.1.105}"
SSH_OPTS=(-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa
          -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1)
ROOT="$(cd .. && pwd)"
S9X_REPO=https://github.com/libretro/snes9x2005.git
S9X_COMMIT=a79dfe9047e7fec58808aefe48ad2bf499c7af11

if [ "${1:-}" = "roms" ]; then
    SRC="$ROOT/roms"
    [ -d "$SRC" ] || { echo "Crie a pasta $SRC e coloque as ROMs nela." >&2; exit 1; }
    echo "==> Enviando ROMs de $SRC"
    ssh "${SSH_OPTS[@]}" "root@$IPAD" 'mkdir -p /var/mobile/Documents/SNES16/roms'
    COPYFILE_DISABLE=1 tar -C "$SRC" -cf - . | ssh "${SSH_OPTS[@]}" "root@$IPAD" \
        'tar -C /var/mobile/Documents/SNES16/roms -xf - && chown -R mobile:mobile /var/mobile/Documents/SNES16 && ls -la /var/mobile/Documents/SNES16/roms'
    exit 0
fi

X13="${X13:-$ROOT/Xcode-13.4.1.app/Contents/Developer}"
TC="$X13/Toolchains/XcodeDefault.xctoolchain/usr/bin"
SDK="$(ls -d "$X13"/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS*.sdk 2>/dev/null | head -1 || true)"
[ -x "$TC/clang" ] && [ -n "$SDK" ] || { echo "Toolchain do Xcode 13 não encontrado em: $X13" >&2; exit 1; }
export DEVELOPER_DIR="$X13"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# --- BTstack (biblioteca do próprio iPad) ---
if [ ! -s vendor/libBTstack.dylib ]; then
    echo "==> Baixando /usr/lib/libBTstack.dylib do iPad ($IPAD)"
    ssh "${SSH_OPTS[@]}" "root@$IPAD" 'cat /usr/lib/libBTstack.dylib' > vendor/libBTstack.dylib.tmp || true
    [ -s vendor/libBTstack.dylib.tmp ] || { echo "Não consegui copiar a libBTstack.dylib do iPad." >&2; exit 1; }
    mv -f vendor/libBTstack.dylib.tmp vendor/libBTstack.dylib
fi
python3 tools/make_link_stub.py vendor/libBTstack.dylib vendor/libBTstackLink.dylib >/dev/null

# --- Core Snes9x 2005 ---
if [ ! -d core/s9x/.git ]; then
    echo "==> Baixando Snes9x 2005 ($S9X_COMMIT)"
    mkdir -p core
    git clone -q "$S9X_REPO" core/s9x
    git -C core/s9x checkout -q "$S9X_COMMIT"
fi

CORE_FLAGS=(-arch armv7 -isysroot "$SDK" -miphoneos-version-min=8.0 -O3 -DNDEBUG -w -DIOS
    -I./source -I. -I./libretro-common/include)

OBJDIR="$PWD/build-core"
CORE_LIB="$OBJDIR/libsnes9x2005.a"
if [ ! -f "$CORE_LIB" ]; then
    echo "==> Compilando o core (primeira vez demora alguns minutos)"
    mkdir -p "$OBJDIR"
    # Lista do Makefile.common (APU padrão, sem blargg; carregamento por arquivo)
    for f in c4 c4emu cheats2 cheats clip cpu cpuexec cpuops data dma dsp1 fxemu fxinst gfx getset globals \
             memmap obc1 ppu sa1 sa1cpu sdd1 sdd1emu seta010 seta011 seta018 seta spc7110 spc7110dec srtc tile \
             apu soundux spc700; do echo "source/$f.c"; done > "$OBJDIR/sources.txt"
    for f in libretro.c compat/compat_posix_string.c compat/compat_strcasestr.c compat/compat_strl.c compat/fopen_utf8.c \
             encodings/encoding_utf.c file/file_path.c file/file_path_io.c streams/file_stream.c \
             streams/file_stream_transforms.c string/stdstring.c time/rtime.c vfs/vfs_implementation.c; do
        case "$f" in libretro.c) echo "$f" ;; *) echo "libretro-common/$f" ;; esac
    done >> "$OBJDIR/sources.txt"
    export TC OBJDIR
    export CORE_FLAGS_STR="$(printf '%q ' "${CORE_FLAGS[@]}")"
    (cd core/s9x && xargs -P "$JOBS" -n 1 bash -c 'eval "flags=($CORE_FLAGS_STR)"; o="$OBJDIR/$(echo "$0" | sed "s#^\./##; s#/#_#g").o"; "$TC/clang" "${flags[@]}" -c "$0" -o "$o" || exit 255' < "$OBJDIR/sources.txt")
    "$TC/libtool" -static -o "$CORE_LIB" "$OBJDIR"/*.o
    echo "==> Core: $(ls "$OBJDIR"/*.o | wc -l | tr -d ' ') arquivos objeto"
fi

# --- App ---
OUT="build/$APP.app"
rm -rf build && mkdir -p "$OUT"
echo "==> Compilando o app (armv7, iOS 8.0)"
"$TC/clang" -arch armv7 -isysroot "$SDK" -miphoneos-version-min=8.0 -B "$TC" \
    -fobjc-arc -O2 -Wall -Wno-unused-parameter -Wunguarded-availability \
    -I src -I vendor/btstack -I core/s9x/libretro-common/include \
    src/*.m src/*.c "$CORE_LIB" -o "$OUT/$APP" \
    -L vendor -lBTstackLink \
    -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore \
    -framework GLKit -framework OpenGLES -framework AudioToolbox -framework AVFoundation

cp Info.plist "$OUT/"
cp resources/*.png resources/*.html "$OUT/"
if command -v ldid >/dev/null 2>&1; then ldid -S "$OUT/$APP"; else codesign -f -s - "$OUT/$APP"; fi
lipo -info "$OUT/$APP"
echo "==> OK: $OUT ($(du -sh "$OUT" | cut -f1))"

if [ "${1:-}" = "install" ]; then
    echo "==> Instalando em /Applications/$APP.app"
    COPYFILE_DISABLE=1 tar -C build -cf - "$APP.app" | ssh "${SSH_OPTS[@]}" "root@$IPAD" \
        "rm -rf /Applications/$APP.app && tar -C /Applications -xf - && chown -R root:wheel /Applications/$APP.app && chmod -R 755 /Applications/$APP.app && mkdir -p /var/mobile/Documents/SNES16/roms && chown -R mobile:mobile /var/mobile/Documents/SNES16 && (su mobile -c uicache || uicache)"
    echo "==> Instalado."
fi
