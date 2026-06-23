# Homebrew formula for isopod.
#
# Install from this repo without a tap:
#   brew install --build-from-source ./Formula/isopod.rb
#   # or track the latest commit:
#   brew install --HEAD ./Formula/isopod.rb
#
# Or publish it as a tap (repo named `homebrew-isopod`) and:
#   brew tap jonathanmcsweet/isopod
#   brew install isopod
#
# Cutting a stable release: tag v<x.y.z>, push, then fill in the sha256 below.
# See RELEASING.md for the exact commands.
class Isopod < Formula
  desc "Disposable, isolated IDE containers that keep AI agents off your host"
  homepage "https://github.com/jonathanmcsweet/isopod"
  url "https://github.com/jonathanmcsweet/isopod/archive/refs/tags/v0.3.0.tar.gz"
  # Placeholder until v0.3.0 is tagged & pushed — replace with the real digest
  # (see RELEASING.md). Until then, install with `--HEAD`.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "Apache-2.0"
  head "https://github.com/jonathanmcsweet/isopod.git", branch: "master"

  depends_on "bash"     # isopod uses bash 4+ features; macOS ships bash 3.2
  depends_on "openssh"  # ssh, ssh-keygen, ssh-keyscan

  # A container engine (podman or docker) is required at runtime but left to the
  # user to install — `brew install podman` then `podman machine init/start` on
  # macOS — because engine choice and setup are environment-specific.

  def install
    # Mirror isopod's symlink install model: keep lib/ and security/ beside the
    # script so it resolves its helpers through the bin symlink.
    libexec.install "isopod", "lib", "security"
    bin.install_symlink libexec/"isopod"

    bash_completion.install "completions/isopod.bash" => "isopod"
    zsh_completion.install "completions/_isopod"
  end

  def caveats
    <<~EOS
      isopod needs a container engine that it does NOT install for you:
        brew install podman   # recommended (rootless); then: podman machine init && podman machine start
      Verify your setup with:
        isopod doctor
    EOS
  end

  test do
    assert_match(/isopod \d+\.\d+\.\d+/, shell_output("#{bin}/isopod version"))
    assert_match "Usage:", shell_output("#{bin}/isopod help")
  end
end
