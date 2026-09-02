# containers

Podman-based development environments with OpenCode and Claude Code.

## What's included

A shared base image (`agent-base`) provides a full multi-language toolchain on Ubuntu 24.04. Two agent images derive from it:

| Image | Agent | Containerfile |
|---|---|---|
| `opencode-dev` | OpenCode | `Containerfile-opencode` |
| `claude-dev` | Claude Code | `Containerfile-claude` |

### Toolchain (base image)

| Language / Domain | Toolchain |
|---|---|
| C / C++ | clang, clangd, clang-format, clang-tidy, clang-tools, cmake, build-essential |
| Java | OpenJDK 21, Maven, Gradle |
| Rust | rustup (minimal), rust-analyzer, clippy, rustfmt, just |
| Python | uv, Python 3.12, pyright, PyTorch (CPU), NumPy, SciPy, pandas, scikit-learn, etc. |
| Android | cmdline-tools, platform-tools (NDK install commented out — enable in Containerfile) |
| CLI tools | ripgrep, fd, git, zsh |

LSP servers (clangd, pyright, rust-analyzer, JDTLS) are managed by the agent at runtime.

## Prerequisites

- [Podman](https://podman.io/) (not Docker)

The launcher locates the Containerfile relative to itself, so the repo can live anywhere on disk. Clone it to wherever you like, e.g. `~/containers`.

## Quick start

### OpenCode

```bash
git clone https://github.com/sgaflv/containers ~/containers
cd /path/to/your/project
~/containers/opencode
```

### Claude Code

```bash
git clone https://github.com/sgaflv/containers ~/containers
cd /path/to/your/project
~/containers/claude
```

On first run the image is built (slow), then a per-project container is created and the agent launches inside it. Subsequent runs reuse the existing container.

## Usage

| Command | Description |
|---|---|
| `opencode` | Launch OpenCode in the current project's container |
| `opencode sh` | Open a bash shell in the existing OpenCode container |
| `opencode rm` | Remove all OpenCode containers and images |
| `claude` | Launch Claude Code in the current project's container |
| `claude sh` | Open a bash shell in the existing Claude container |
| `claude rm` | Remove all Claude containers and images |

Each project gets its own container (`opencode-<projectname>` or `claude-<projectname>`), so bind mounts never cross projects.

## Security

- `--cap-drop=ALL` — all Linux capabilities dropped
- `--security-opt=no-new-privileges` — prevents privilege escalation
- `--userns=keep-id` — UID/GID mapped to match the host user
- Agent config (`~/.config/opencode` or `~/.claude`) is bind-mounted, not baked into the image

## Customization

- **UID/GID:** Pass build args `--build-arg UID=$(id -u) --build-arg GID=$(id -g)` to match your host user.
- **PyTorch GPU:** Replace the CPU `--index-url` in the Containerfile with the appropriate CUDA index.
- **Android NDK:** Uncomment the `sdkmanager` install step in the Containerfile and accept licenses during build.
