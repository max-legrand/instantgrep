class Igrep < Formula
  desc "Fast regex search using trigram indexes"
  homepage "https://github.com/GrowlyX/igrep"
  version "0.0.1"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/GrowlyX/igrep/releases/download/v#{version}/igrep-darwin-arm64.tar.gz"
      sha256 "PLACEHOLDER"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/GrowlyX/igrep/releases/download/v#{version}/igrep-linux-amd64.tar.gz"
      sha256 "PLACEHOLDER"
    end
  end

  depends_on "erlang"

  def install
    bin.install "igrep"
    bin.install "igrep-bench"
  end

  test do
    assert_match "igrep", shell_output("#{bin}/igrep --help")
  end
end
