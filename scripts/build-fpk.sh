#!/usr/bin/env bash
#
# 构建 Ekko Studio 飞牛 fpk 安装包
#
# 用法：
#   bash scripts/build-fpk.sh            # 生成 ekko-studio.fpk（项目根目录）
#   bash scripts/build-fpk.sh dist       # 额外复制为 dist/fnos-ekko-studio_v<version>.fpk
#
# 构建方式（优先级）：
#   1. 官方 fnpack（推荐）：自动探测 fnpack / fnpack.exe（含仓库根目录的 fnpack.exe）。
#      由飞牛官方工具生成，格式 100% 合规，会做安装前文件/格式校验。
#   2. 纯 tar+gzip 兜底（无 fnpack 时）：复刻官方双层 tar.gz 格式，可复现，
#      在任意 Linux / macOS / Git Bash 均可运行，不依赖 fnpack。
#
# ⚠️ 两个名字不要混：
#   APPNAME = manifest 里的 appname（技术标识，= fnpack 产出的 ekko-studio.fpk）
#   PKGNAME = 发布给用户的文件名前缀（fnos-ekko-studio_v<ver>.fpk）
# 当前两者同值；保留两个变量是为了将来「技术标识不变但改发布名」时不用再拆一次。
set -e

APPNAME="ekko-studio"
PKGNAME="ekko-studio"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT_DIR="${1:-.}"
mkdir -p "$OUT_DIR"

VERSION="$(grep '^version' manifest | awk -F'=' '{print $2}' | tr -d ' ')"
if [ -z "$VERSION" ]; then
    echo "无法从 manifest 读取 version" >&2
    exit 1
fi

# ── 准备 Hermes Agent 离线源码包（可选但强烈建议） ──
# 很多 NAS 无法稳定连接 GitHub，安装时 git clone 会失败，导致应用启动不了。
# 构建时把源码包嵌入 FPK，install_callback 会优先用它而跳过网络 clone。
# 该目录不入 git（见 .gitignore），每次构建时按需下载/复用。
ensure_hermes_agent_src() {
    local src_dir="$ROOT/app/hermes-agent-src"
    local marker="$src_dir/.offline-bundle"
    local ref_marker="$src_dir/.bundled-agent-ref"
    local agent_ver="main"
    local agent_env="$ROOT/config/bootstrap/hermes-agent-version.env"
    if [ -f "$agent_env" ]; then
        agent_ver="$(grep -E '^HERMES_AGENT_VERSION=' "$agent_env" | awk -F'=' '{print $2}' | tr -d ' ')"
        [ -z "$agent_ver" ] && agent_ver="main"
    fi
    local tmp_tar="$ROOT/.hermes-agent.tar.gz"

    # 缓存/手动放置的源码包处理：
    # - 有 ref 标记且与当前 HERMES_AGENT_VERSION 一致 → 直接复用
    # - 有 ref 标记但 ref 不一致（env 已变更）→ 重新下载对齐
    # - 无 ref 标记（手动放置 / 旧式缓存）→ 直接复用，不覆盖用户放置的内容
    if [ -d "$src_dir" ] && [ -f "$src_dir/pyproject.toml" ]; then
        if [ -f "$ref_marker" ]; then
            if [ "$(cat "$ref_marker" 2>/dev/null)" = "$agent_ver" ]; then
                echo "使用已缓存的 Hermes Agent 源码包: $src_dir (ref=$agent_ver)"
                return 0
            fi
            echo "缓存 Agent 源码 ref($(cat "$ref_marker" 2>/dev/null)) 与当前 $agent_ver 不一致，重新下载"
            rm -rf "$src_dir"
        else
            echo "使用手动放置的 Hermes Agent 源码包: $src_dir"
            return 0
        fi
    fi

    echo "准备 Hermes Agent 离线源码包..."
    rm -rf "$src_dir" "$tmp_tar"
    mkdir -p "$src_dir"

    # 追踪的 agent release 标签已在函数顶部读取为 agent_ver（默认回退 main 保证兼容），
    # 由 .github/workflows/auto-update.yml 自动与上游最新 release 对齐。
    local url="https://api.github.com/repos/NousResearch/hermes-agent/tarball/${agent_ver}"
    local attempt=1
    local downloaded=false
    while [ $attempt -le 3 ]; do
        echo "  尝试 $attempt/3 下载 $url ..."
        if curl -fsSL --max-time 300 "$url" -o "$tmp_tar" 2>/dev/null; then
            downloaded=true
            break
        fi
        echo "  下载失败，重试..."
        attempt=$((attempt + 1))
        sleep 5
    done

    # 钉的 release 标签下载失败（如标签被删/网络抖动）时，回退到 main 分支，
    # 保证离线源码包仍能生成（代价是失去该次的可复现性，仅作兜底）。
    if [ "$downloaded" != "true" ] && [ "$agent_ver" != "main" ]; then
        echo "WARNING: 按标签 $agent_ver 下载失败，回退到 main 分支"
        url="https://api.github.com/repos/NousResearch/hermes-agent/tarball/main"
        attempt=1
        while [ $attempt -le 3 ]; do
            if curl -fsSL --max-time 300 "$url" -o "$tmp_tar" 2>/dev/null; then
                downloaded=true
                agent_ver="main"
                break
            fi
            attempt=$((attempt + 1))
            sleep 5
        done
    fi

    if [ "$downloaded" != "true" ]; then
        echo "WARNING: 无法下载 Hermes Agent 源码包（GitHub 网络问题）。"
        echo "  本次构建不会包含离线源码，NAS 安装时仍会尝试 git clone。"
        echo "  如需离线包，可手动把 hermes-agent 仓库放到 $src_dir 后再构建。"
        rm -rf "$src_dir" "$tmp_tar"
        return 0
    fi

    echo "  下载完成，解压中..."
    mkdir -p "$ROOT/.ha-extract"
    if ! tar -xzf "$tmp_tar" -C "$ROOT/.ha-extract" --strip-components=1 2>/dev/null; then
        echo "WARNING: 解压 Hermes Agent 源码包失败"
        rm -rf "$src_dir" "$tmp_tar" "$ROOT/.ha-extract"
        return 0
    fi

    # 移动到目标目录
    mv "$ROOT/.ha-extract"/* "$src_dir/" 2>/dev/null || true
    rm -rf "$ROOT/.ha-extract" "$tmp_tar"

    if [ ! -f "$src_dir/pyproject.toml" ]; then
        echo "WARNING: 源码包解压后未找到 pyproject.toml"
        rm -rf "$src_dir"
        return 0
    fi

    # 初始化为 git 仓库，让 install.sh 的离线模式识别
    (
        cd "$src_dir"
        git init -q 2>/dev/null || true
        git config user.email "build@local" 2>/dev/null || true
        git config user.name "FPK Builder" 2>/dev/null || true
        git add -A 2>/dev/null || true
        git commit -q -m "offline bundle" 2>/dev/null || true
    )

    touch "$marker"
    echo "$agent_ver" > "$ref_marker"
    echo "Hermes Agent 离线源码包已准备: $src_dir (ref=$agent_ver)"
}

ensure_hermes_agent_src

# ── 准备 bundled node（hermes-web-ui 预装 node_modules，含编译好的原生 node-pty） ──
# 根因：早期 FPK 未打进 app/node，install_callback 回退 npm install -g，而 fnOS 缺
# 少 gcc/g++ 无法编译 node-pty（原生模块），导致安装卡死/超时（UI 停在 ~55%）。
# 现在优先从官方 GitHub Release（EKKOLearnAI/ekko-studio）下载「预构建好的 web-ui 包」
# （hermes-web-ui-${ver}.tar.gz，含 bin/dist/node_modules，node-pty 原生模块已编译），
# 与上游 release 严格对齐且比 npm 发布更及时；下载失败再回退 npm install -g 编译。
# 打包进 FPK 后，安装时 install_callback 直接走 Path A（离线复制，几秒完成）。
ensure_node_bundle() {
    local ver_file="$ROOT/config/bootstrap/hermes-studio-version.env"
    local ver="0.6.33"
    if [ -f "$ver_file" ]; then
        ver="$(grep -E '^HERMES_STUDIO_VERSION=' "$ver_file" | awk -F'=' '{print $2}' | tr -d ' ')"
        [ -z "$ver" ] && ver="0.6.33"
    fi

    local node_dir="$ROOT/app/node"
    local pkg_dir="$node_dir/lib/node_modules/hermes-web-ui"
    local bin_mjs="$pkg_dir/bin/hermes-web-ui.mjs"

    # 已存在则复用（本地增量构建 / 缓存）
    if [ -f "$bin_mjs" ] && [ -f "$pkg_dir/package.json" ]; then
        echo "使用已缓存的 bundled node: $node_dir (hermes-web-ui@$ver)"
    else
        echo "准备 bundled node（获取 hermes-web-ui@$ver）..."
        rm -rf "$node_dir"
        mkdir -p "$node_dir"

        # 官方在 GitHub Release 上随版本即时发布预构建好的 web-ui 包
        # （含 bin/dist/node_modules，node-pty 原生模块已编译），比 npm 发布更及时，
        # 且与上游 release 严格对齐。优先用官方产物；下载失败再回退 npm 编译。
        local asset="hermes-web-ui-${ver}.tar.gz"
        local url="https://github.com/EKKOLearnAI/ekko-studio/releases/download/v${ver}/${asset}"
        local tmp
        tmp="$(mktemp -d)"
        local ok=0

        # ── 供应链校验：先取「入库固定的 sha256」，没有才退回上游 sidecar ──
        # 只做「现拉 sidecar 现比」挡不住上游事后替换同版本资产（sidecar 会跟着
        # 一起变，等于没校验）。固定值进版本控制才能发现变更。
        local expected="" sha_source=""
        local pinned_env="$ROOT/config/upstream/${asset}.env"
        if [ -f "$pinned_env" ]; then
            expected="$(grep -E '^HERMES_WEB_UI_SHA256=' "$pinned_env" | cut -d= -f2 | tr -d ' ')"
            [ -n "$expected" ] && sha_source="pinned:config/upstream/${asset}.env"
        fi

        if curl -fSL --max-time 300 -o "$tmp/$asset" "$url" 2>/dev/null; then
            echo "已下载官方预构建产物: $url"

            # 没有固定值时，退回拉取上游 <asset>.sha256 sidecar
            if [ -z "$expected" ]; then
                if curl -fSL --max-time 60 -o "$tmp/${asset}.sha256" "${url}.sha256" 2>/dev/null; then
                    expected="$(awk '{print $1}' "$tmp/${asset}.sha256" | head -1)"
                    sha_source="sidecar:${asset}.sha256"
                fi
            fi

            # 计算实际值并逐字比对
            local actual
            actual="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
            if [ -z "$expected" ]; then
                echo "::error:: 无法获得 ${asset} 的 sha256（固定值与 sidecar 均缺失），拒绝使用未校验的外部产物"
                exit 1
            fi
            if [ "$actual" != "$expected" ]; then
                echo "::error:: ${asset} sha256 校验失败！"
                echo "  期望(${sha_source}): $expected"
                echo "  实际:               $actual"
                echo "  上游可能替换了同版本资产，或下载被篡改。构建中止。"
                exit 1
            fi
            echo "✅ ${asset} sha256 校验通过 ($sha_source): $actual"

            mkdir -p "$pkg_dir"
            tar -xzf "$tmp/$asset" -C "$tmp"
            if [ -d "$tmp/webui" ]; then
                cp -a "$tmp/webui/." "$pkg_dir/"
                ok=1
            else
                echo "::warning:: 官方产物结构异常（缺少顶层 webui/），回退 npm install"
            fi
        else
            echo "::warning:: 下载官方产物失败（$url），回退 npm install -g hermes-web-ui@$ver"
        fi

        if [ "$ok" != "1" ]; then
            # 回退路径：npm install（需 gcc/g++ 编译 node-pty）
            for t in gcc g++ make python3 node npm; do
                if ! command -v "$t" >/dev/null 2>&1; then
                    echo "::error:: 回退 npm 编译缺少必需工具: $t" >&2
                    exit 1
                fi
            done
            echo "node: $(node --version)  npm: $(npm --version)"
            if ! npm install -g --no-audit --no-fund --prefix "$node_dir" "hermes-web-ui@${ver}"; then
                echo "::error:: npm install hermes-web-ui@${ver} 失败" >&2
                exit 1
            fi
        fi

        rm -rf "$tmp"

        # 创建 bin 软链（与 npm install -g 产物布局一致，install_callback 也会重建）
        mkdir -p "$node_dir/bin"
        ln -sf "../lib/node_modules/hermes-web-ui/bin/hermes-web-ui.mjs" "$node_dir/bin/hermes-web-ui"

        if [ ! -f "$bin_mjs" ]; then
            echo "::error:: bundled hermes-web-ui 入口缺失: $bin_mjs" >&2
            exit 1
        fi
    fi

    # 校验 node-pty 原生模块确实编译出来了（不是只下了 prebuilds/）
    local npty_dir="$pkg_dir/node_modules/node-pty"
    if [ -d "$npty_dir" ]; then
        local built
        built=$(ls "$npty_dir"/build/Release/*.node 2>/dev/null | head -1)
        if [ -z "$built" ]; then
            # 也许 node-pty 被 hoist 到更外层
            built=$(find "$node_dir/lib/node_modules" -path '*/node-pty/build/Release/*.node' 2>/dev/null | head -1)
        fi
        if [ -n "$built" ]; then
            echo "✅ node-pty 原生模块已编译: $built"
        else
            echo "::error:: 未找到 node-pty 编译产物（build/Release/*.node），bundled node 不完整，构建中止" >&2
            exit 1
        fi
    else
        echo "::error:: 未找到 node-pty 目录，bundled node 可能不完整，构建中止" >&2
        exit 1
    fi

    echo "bundled node 准备完成: $node_dir"
}

ensure_node_bundle

# ── 准备 agent 的 bundled node_modules（browser tools + TUI 依赖）──
# 根因：官方 installer 在首启后台跑 `npm install`（root 依赖 agent-browser /
# @streamdown/math = browser tools + ui-tui workspace），默认 NODE_DEPS_TIMEOUT=600s，
# NAS 联网慢/无网时会卡很久（UI 一直 starting）。这里在 CI（有网 + Node v24）把依赖
# 装好，按相对路径镜像进 app/hermes-agent-node/；install_callback 检测到后直接复制
# 并跳过 npm install，首启不再长时间等待。
ensure_hermes_agent_node_bundle() {
    local src_dir="$ROOT/app/hermes-agent-src"
    local node_bundle="$ROOT/app/hermes-agent-node"
    local work

    # 无源码或本地缺 node/npm 时跳过：不阻断整体构建，安装回退到在线 npm install。
    if [ ! -f "$src_dir/package.json" ]; then
        echo "未找到 hermes-agent-src/package.json，跳过 agent node bundle"
        return 0
    fi
    for t in node npm; do
        if ! command -v "$t" >/dev/null 2>&1; then
            echo "WARNING: 构建 agent node bundle 缺少 $t，跳过（安装将回退在线 npm）"
            return 0
        fi
    done

    # 已存在且关键 node_modules 已生成则复用（本地增量/缓存）
    if [ -d "$node_bundle/node_modules" ]; then
        echo "使用已缓存的 agent node bundle: $node_bundle"
        return 0
    fi

    echo "准备 agent node bundle（browser tools + TUI 依赖）..."
    rm -rf "$node_bundle"
    mkdir -p "$node_bundle"
    # 关键：用尾斜杠把源码「内容」复制到 work 根目录，避免 cp 生成
    # work/<src_basename>/ 嵌套层。嵌套层会把构建机绝对路径（如
    # /home/runner/work/.../.agent-node-work）带进 hermes-agent-node/，
    # 导致 install_callback 找不到 hermes-agent-node/node_modules 而回退 npm install。
    work="$(mktemp -d)"
    # 排除 .git：hermes-agent-src 内的 .git 由 build.yml 的 git init 生成，
    # 其松散对象（objects/xx）在 git 自动 gc 打包后会被清除，cp -a 会 stat 失败
    # 导致整个打包中断（偶发，取决于 gc 时机）。node bundle 只需源码文件，不需要 .git。
    # 用 tar 管道复制并排除 .git，既绕开 cp 的 stat 竞态，也不把 .git 带进 hermes-agent-node。
    tar -C "$src_dir" --exclude='.git' -cf - . | tar -xf - -C "$work"

    (
        cd "$work"
        echo "node: $(node --version)  npm: $(npm --version)"
        # 1) root 依赖（agent-browser / @streamdown/math = browser tools），只装 root 不装 workspace
        if ! npm install --no-audit --no-fund --omit=dev --no-workspaces --include-workspace-root \
                >>/tmp/agent_node_build.log 2>&1; then
            echo "::warning:: agent root npm install 失败，agent node bundle 可能不完整（安装将回退在线 npm）"
        fi
        # 2) TUI workspace（含 ui-tui/packages/hermes-ink 与 apps/shared 的 file: 依赖）
        if ! npm install --no-audit --no-fund --omit=dev --workspace ui-tui \
                >>/tmp/agent_node_build.log 2>&1; then
            echo "::warning:: agent tui npm install 失败，TUI 可能不可用（安装将回退在线 npm）"
        fi
    ) || true

    # 收集每个含 package.json 的目录（排除 node_modules 内）的 node_modules，
    # 按「相对 agent 源码根」的路径镜像进 hermes-agent-node/<rel>/node_modules。
    # install_callback 端 find hermes-agent-node -name node_modules 后套用相同相对结构
    # 复制回 Agent 目录，因此这里 rel 必须是干净的相对路径（绝不可含构建机绝对路径）。
    local count=0
    while IFS= read -r pkgroot; do
        [ -d "$pkgroot/node_modules" ] || continue
        local rel
        rel="$(realpath --relative-to="$work" "$pkgroot")"
        # 防御：若相对路径异常（绝对路径或意外混入构建机路径），跳过以免污染包
        case "$rel" in
            /*|*runner*|*.agent-node-work*)
                echo "::warning:: 跳过异常的 node_modules 路径: $rel"
                continue ;;
        esac
        [ "$rel" = "." ] && rel=""
        mkdir -p "$node_bundle/$rel"
        cp -a "$pkgroot/node_modules" "$node_bundle/$rel/"
        count=$((count + 1))
    done < <(find "$work" -name package.json -not -path '*/node_modules/*' -exec dirname {} \;)

    rm -rf "$work"

    if [ -d "$node_bundle/node_modules" ]; then
        echo "✅ agent node bundle 已生成: $node_bundle (共 $count 个 node_modules 树)"
    else
        echo "::warning:: agent node bundle 未生成 node_modules，安装将回退在线 npm"
    fi
}

ensure_hermes_agent_node_bundle

# ── 统一生命周期脚本与 CLI 包装脚本的可执行位 ──
# git 只在文件模式变化时记录 mode，新建文件默认 644 极易漏；644 会让
# uninstall_init 里的 [ -x "${TRIM_APPDEST}/cmd/main" ] 判断失败，
# 卸载/升级静默跳过 stop，残留进程占着端口。这里在打包前无条件纠正。
chmod 755 cmd/* 2>/dev/null || true
chmod 755 app/bin/* 2>/dev/null || true
BAD_PERM="$(find cmd app/bin -maxdepth 1 -type f ! -perm -u+x 2>/dev/null)"
if [ -n "${BAD_PERM}" ]; then
    echo "::error:: 以下文件缺可执行位，fnOS 会静默跳过 stop：" >&2
    echo "${BAD_PERM}" >&2
    exit 1
fi
echo "✅ cmd/* 与 app/bin/* 均可执行 (755)"

# ── 规范化 app/ 目录权限与属主 ──
# 根因：CI runner（uid=1001）打包时会把 runner 的 uid/gid 写入 app.tgz。
# fnOS 解压后若尝试 chown 到应用用户，某些只读/特殊权限文件可能失败，
# 导致应用中心报"设置目录权限失败"。这里在打包前统一规范化：
#   - 所有文件对所有人可读，目录可进入
#   - 保留原有可执行位（bin/ 脚本、.node 等）
#   - 去掉 setuid/setgid/sticky 等特殊位
#   - 尽量把属主归到 root（CI 若没 root 则忽略失败）
normalize_app_permissions() {
    echo "规范 app/ 目录权限，避免带入构建机属主..."
    # 先尝试把属主改成 root:root；CI 普通用户会失败，不影响后续
    chown -R root:root app/ 2>/dev/null || true
    # 去掉特殊权限位（setuid/setgid/sticky），保留普通 rwx
    find app/ -type f -exec chmod a-s {} + 2>/dev/null || true
    find app/ -type d -exec chmod a-s {} + 2>/dev/null || true
    # 目录统一 755
    find app/ -type d -exec chmod 755 {} + 2>/dev/null || true
    # 普通文件统一 644
    find app/ -type f -exec chmod 644 {} + 2>/dev/null || true
    # 恢复真正需要可执行的文件：shebang 脚本、.mjs CLI、二进制、.so/.node
    find app/ -type f \( -name '*.sh' -o -name '*.mjs' -o -name '*.js' -o -name '*.cjs' \
        -o -name '*.node' -o -name '*.so' -o -name '*.so.*' -o -name 'hermes' \
        -o -name 'python3*' -o -name 'uv' -o -name 'uvx' \) \
        -exec chmod 755 {} + 2>/dev/null || true
    # 对 node_modules/.bin 下的 wrapper 也加可执行
    if [ -d app/node/lib/node_modules/.bin ]; then
        chmod -R 755 app/node/lib/node_modules/.bin/* 2>/dev/null || true
    fi
    if [ -d app/node/bin ]; then
        chmod -R 755 app/node/bin/* 2>/dev/null || true
    fi
    echo "app/ 权限规范化完成"
}

normalize_app_permissions

# ── FPK 后处理：移除软链、统一属主为 root、正规化权限 ──
# 根因：CI runner 以 uid=1001 构建，npm install -g 会生成 bin/ 软链；fnpack 把这些
# 原样打进 app.tgz。飞牛应用中心解压后再设置权限时，遇到：
#   1) 属主为 1001 的文件（非 root），某些 chown 场景下失败；
#   2) 软链自引用或指向不存在目标（Windows/Git Bash 下 npm 软链易损坏），
#      chmod/chown 递归处理时直接报错"设置目录权限失败"。
# 因此构建完成后必须对 FPK 做一次后处理：把 app.tgz 里所有软链/硬链去掉，
# 所有条目 uid/gid 重置为 0，权限正规化，再重新计算 checksum 打包。
postprocess_fpk() {
    local src="$1" dst="$2"
    echo "后处理 FPK：移除软链、重置属主、正规化权限 ..."
    python3 - "$src" "$dst" <<'PY'
import tarfile, hashlib, io, os, tempfile, shutil, gzip, sys

def sanitize_app_tgz(data):
    in_buf = io.BytesIO(data)
    in_tar = tarfile.open(fileobj=in_buf, mode='r:gz')
    out_buf = io.BytesIO()
    out_tar = tarfile.open(fileobj=out_buf, mode='w:gz', compresslevel=9)
    removed = 0
    kept = 0
    for m in in_tar.getmembers():
        if m.issym() or m.islnk():
            # 保留 node_modules 内的软链：npm 的 workspace 链接（如
            # node_modules/@hermes/shared -> ../../apps/shared）与 .bin 链接都是
            # 相对且有效的，解压后在包内可解析；剥离它们会导致 agent 的
            # @hermes/shared / @hermes/ink 等依赖无法解析（TUI 启动失败）。
            # 只剥离 node_modules 之外的软链（如 app/node/bin 下自引用/损坏的
            # bin 链接），这些由 install_callback 的 fix_bundled_bin_links 重建。
            if '/node_modules/' in m.name:
                m.uid = 0
                m.gid = 0
                m.uname = 'root'
                m.gname = 'root'
                try:
                    f = in_tar.extractfile(m)
                except Exception as e:
                    print(f"WARN: extract symlink {m.name} failed: {e}", file=sys.stderr)
                    removed += 1
                    continue
                out_tar.addfile(m, f)
                kept += 1
            else:
                removed += 1
            continue
        # 统一属主为 root
        m.uid = 0
        m.gid = 0
        m.uname = 'root'
        m.gname = 'root'
        # 正规化权限
        if m.isdir():
            m.mode = 0o755
        else:
            # 任何可执行位 => 755，否则 644
            m.mode = 0o755 if (m.mode & 0o111) else 0o644
        m.mode &= ~0o7000  # 去掉 setuid/setgid/sticky
        try:
            f = in_tar.extractfile(m)
        except Exception as e:
            print(f"WARN: extract {m.name} failed: {e}", file=sys.stderr)
            continue
        out_tar.addfile(m, f)
        kept += 1
    out_tar.close()
    print(f"  app.tgz: removed {removed} symlinks/hardlinks, kept {kept} regular members")
    return out_buf.getvalue()

src, dst = sys.argv[1], sys.argv[2]
tmp = tempfile.mkdtemp()
try:
    # 解外层 FPK
    outer = tarfile.open(src, 'r:gz')
    app_data = outer.extractfile('app.tgz').read()
    for m in outer.getmembers():
        if m.name == 'app.tgz':
            continue
        outer.extract(m, tmp)
    outer.close()

    # 清洗 app.tgz
    new_app = sanitize_app_tgz(app_data)
    checksum = hashlib.md5(new_app).hexdigest()

    # 更新 manifest
    manifest_path = os.path.join(tmp, 'manifest')
    with open(manifest_path, 'rb') as f:
        content = f.read().replace(b'\r\n', b'\n')
    lines = content.decode('utf-8').splitlines(keepends=True)
    with open(manifest_path, 'w', encoding='utf-8', newline='\n') as f:
        for line in lines:
            if line.startswith('checksum'):
                f.write(f'checksum              = {checksum}\n')
            else:
                f.write(line)

    # manifest.checksum
    with open(os.path.join(tmp, 'manifest.checksum'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(checksum + '\n')

    # 重打外层 FPK：manifest -> manifest.checksum -> 其他 -> app.tgz
    out = io.BytesIO()
    out_tar = tarfile.open(fileobj=out, mode='w')
    order = ['manifest', 'manifest.checksum']
    other = sorted([m.name for m in tarfile.open(src, 'r:gz').getmembers()
                    if m.name not in ('manifest', 'manifest.checksum', 'app.tgz')])
    order.extend(other)
    order.append('app.tgz')

    for name in order:
        if name == 'app.tgz':
            info = tarfile.TarInfo(name='app.tgz')
            info.size = len(new_app)
            info.mode = 0o644
            info.uid = 0
            info.gid = 0
            out_tar.addfile(info, io.BytesIO(new_app))
        else:
            full = os.path.join(tmp, name)
            if os.path.isdir(full):
                info = tarfile.TarInfo(name=name)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                info.uid = 0
                info.gid = 0
                out_tar.addfile(info)
            else:
                out_tar.add(full, arcname=name)
    out_tar.close()

    with gzip.open(dst, 'wb', compresslevel=9) as gz:
        gz.write(out.getvalue())
    print(f"  postprocess OK: {dst}")
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PY
}

# ── 探测 fnpack ──
FNPACK=""
for cand in "$ROOT/fnpack.exe" "$ROOT/fnpack" fnpack fnpack.exe; do
    if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then
        FNPACK="$cand"
        break
    fi
done

if [ -n "$FNPACK" ]; then
    echo "使用官方 fnpack 构建：$FNPACK"
    "$FNPACK" build
    SRC_FPK="${APPNAME}.fpk"
    if [ ! -f "$SRC_FPK" ]; then
        echo "fnpack 未生成 $SRC_FPK" >&2
        exit 1
    fi

    # fnpack 某些版本/平台不会生成 manifest.checksum，但飞牛应用中心校验需要该文件。
    # 用 Python 跨平台地补充 manifest.checksum 并更新 manifest checksum 字段。
    if ! python3 -c "import tarfile, sys; sys.exit(0 if 'manifest.checksum' in [m.name for m in tarfile.open('${SRC_FPK}','r:gz').getmembers()] else 1)" 2>/dev/null; then
        echo "fnpack 未生成 manifest.checksum，手动补充..."
        python3 - "$SRC_FPK" <<'PY'
import tarfile, hashlib, io, os, sys, tempfile, shutil, gzip
src = sys.argv[1]
t = tarfile.open(src, 'r:gz')
app_data = t.extractfile('app.tgz').read()
sum_val = hashlib.md5(app_data).hexdigest()
tmp = tempfile.mkdtemp()
# tarfile.extract(m, path, filter=...) 的 filter 参数是 Python 3.12+ 才有；
# 3.11 会报 TypeError: unexpected keyword argument 'filter'。用 try/except 兼容两者。
for m in t.getmembers():
    try:
        t.extract(m, tmp, filter='fully_trusted')
    except TypeError:
        t.extract(m, tmp)
manifest_path = os.path.join(tmp, 'manifest')
with open(manifest_path, 'rb') as f:
    content = f.read().replace(b'\r\n', b'\n')
lines = content.decode('utf-8').splitlines(keepends=True)
with open(manifest_path, 'w', encoding='utf-8', newline='\n') as f:
    for line in lines:
        if line.startswith('checksum'):
            f.write(f'checksum              = {sum_val}\n')
        else:
            f.write(line)
with open(os.path.join(tmp, 'manifest.checksum'), 'w', encoding='utf-8', newline='\n') as f:
    f.write(sum_val + '\n')
out = io.BytesIO()
out_tar = tarfile.open(fileobj=out, mode='w')
members = t.getmembers()
name_to_member = {m.name: m for m in members}
order = ['manifest'] + [m.name for m in members if m.name not in ('manifest', 'manifest.checksum')]
order.insert(1, 'manifest.checksum')
for name in order:
    if name == 'manifest.checksum':
        out_tar.add(os.path.join(tmp, 'manifest.checksum'), arcname='manifest.checksum')
    else:
        full = os.path.join(tmp, name)
        if os.path.isdir(full):
            out_tar.addfile(name_to_member[name])
        else:
            out_tar.add(full, arcname=name)
out_tar.close()
with gzip.open(src, 'wb', compresslevel=9) as gz:
    gz.write(out.getvalue())
shutil.rmtree(tmp)
print(f'manifest.checksum added: {sum_val}')
PY
        echo "已补充 manifest.checksum"
    fi

    # 后处理：移除软链、重置属主、正规化权限（避免 fnOS 报"设置目录权限失败"）
    postprocess_fpk "$SRC_FPK" "$SRC_FPK"

    if [ "$OUT_DIR" != "." ]; then
        cp "$SRC_FPK" "${OUT_DIR}/fnos-${PKGNAME}_v${VERSION}.fpk"
        echo "已生成: ${OUT_DIR}/fnos-${PKGNAME}_v${VERSION}.fpk"
    fi
    # 取 checksum 供展示
    SUM="$(tar xzf "$SRC_FPK" -O manifest 2>/dev/null | grep '^checksum' | awk -F'= ' '{print $2}')"
    echo "checksum=${SUM}"
    exit 0
fi

echo "未找到 fnpack，回退到纯 tar+gzip 构建"

# ── 兜底：纯 tar+gzip 复刻官方双层 tar.gz 格式 ──
# 1. 内层 app.tgz —— 必须把 app/ 的【内容】打在归档根：
#    官方 fnpack 产出的是 bin/ config/ node/ ui/，既没有 app/ 这一层，
#    也没有 ./ 开头条目。带 app/ 前缀装完是 @appcenter/<app>/app/node/...，
#    而 install_callback 找的是 @appcenter/<app>/node/... —— 四个关键路径
#    全部对不上，安装必失败。显式列条目是唯一正确写法。
APP_ENTRIES="$(cd app && ls -A)"
[ -n "${APP_ENTRIES}" ] || { echo "::error:: app/ 目录为空，无法构建内层归档" >&2; exit 1; }
# shellcheck disable=SC2086
tar --owner=root --group=root --mtime='@0' -cf - -C app ${APP_ENTRIES} | gzip -n > app.tgz
FIRST_ENTRY="$(tar tzf app.tgz | head -1)"
case "${FIRST_ENTRY}" in
    app/*|./*)
        echo "::error:: 内层 app.tgz 首条为 '${FIRST_ENTRY}'，带 app/ 或 ./ 前缀，装完路径会全错位" >&2
        exit 1
        ;;
esac
echo "内层 app.tgz 首条: ${FIRST_ENTRY}（无前缀，符合官方格式）"

# 2. checksum = app.tgz 的 MD5
if command -v md5sum >/dev/null 2>&1; then
    SUM="$(md5sum app.tgz | awk '{print $1}')"
elif command -v md5 >/dev/null 2>&1; then
    SUM="$(md5 -q app.tgz)"
else
    echo "缺少 md5sum / md5 工具" >&2
    exit 1
fi

# 3. 将 checksum 写回 manifest（整行替换，幂等，不叠加旧值）
sed "s/^checksum[[:space:]]*=.*/checksum              = ${SUM}/" manifest > manifest.tmp && mv manifest.tmp manifest

# 4. 生成 manifest.checksum 文件（飞牛应用中心会校验）
echo "$SUM" > manifest.checksum

# 5. 外层 tar.gz
tar --owner=root --group=root --mtime='@0' -cf - manifest manifest.checksum cmd config wizard ICON.PNG ICON_256.PNG app.tgz | gzip -n > "${OUT_DIR}/${APPNAME}.fpk"
rm -f manifest.checksum || true
rm -f app.tgz || true

# 6. 后处理：移除软链、重置属主、正规化权限
TARGET="${OUT_DIR}/${APPNAME}.fpk"
postprocess_fpk "$TARGET" "$TARGET"

# 7. 若指定了输出目录，重命名为带版本号的最终文件名
if [ "$OUT_DIR" != "." ]; then
    FINAL="${OUT_DIR}/fnos-${PKGNAME}_v${VERSION}.fpk"
    mv "$TARGET" "$FINAL"
    echo "已生成: $FINAL (checksum=${SUM})"
else
    echo "已生成: $TARGET (checksum=${SUM})"
fi
