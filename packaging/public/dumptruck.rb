# typed: strict
# frozen_string_literal: true

require "uri"

# Installs the Dumptruck engine, CLI, and native macOS application.
class Dumptruck < Formula
  include Language::Python::Virtualenv

  desc "Verified camera-media offload engine and macOS app"
  homepage "https://github.com/MIM18-code/dumptruck"
  license "Apache-2.0"

  local_archive = ENV.fetch("HOMEBREW_DUMPTRUCK_LOCAL_ARCHIVE", nil)
  if local_archive
    url "file://#{URI::DEFAULT_PARSER.escape(File.expand_path(local_archive))}"
    version "0.5.6"
    sha256 ENV.fetch("HOMEBREW_DUMPTRUCK_LOCAL_ARCHIVE_SHA256")
  else
    # HTTPS, not SSH: the reference install Mac (and most alpha testers)
    # authenticate to the private repo through a keychain/gh git credential
    # helper; no SSH key is required or assumed.
    head "https://github.com/MIM18-code/dumptruck.git", using: :git, branch: "main"
  end

  depends_on "ffmpeg"
  depends_on "python@3.13"

  resource "xxhash" do
    url "https://files.pythonhosted.org/packages/f6/a5/1386f35da1475fcaeef42581deae73417c6d2a6a0b2d2e8914de18844dcd/xxhash-4.0.1.tar.gz"
    sha256 "d55bf4ef10eb09b8b6866790e083d26d087d84caa3cc0946ba87c3ca7ecaf7b7"
  end

  def install
    libexec.install "dumptruck"

    venv = virtualenv_create(libexec/".venv", formula_opt_bin("python@3.13")/"python3.13",
                             system_site_packages: false)
    venv.pip_install resource("xxhash")
    venv_bin = libexec/".venv/bin"
    venv_bin.install_symlink formula_opt_bin("ffmpeg")/"ffmpeg"
    venv_bin.install_symlink formula_opt_bin("ffmpeg")/"ffprobe"

    (bin/"dumptruck").write <<~SH
      #!/bin/bash
      set -e
      cd "#{libexec}"
      export PATH="#{venv_bin}:$PATH"
      exec "#{venv_bin}/python" -m dumptruck.cli "$@"
    SH

    cd "DumptruckApp" do
      system "swift", "build", "-c", "release", "--disable-sandbox"
      with_env(
        DUMPTRUCK_ENGINE_ROOT:             libexec.to_s,
        DUMPTRUCK_SWIFTPM_DISABLE_SANDBOX: "1",
      ) do
        system "./make_app.sh"
      end
      prefix.install "build/Dumptruck.app"
    end
    libexec.install "LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "LICENSES"
  end

  def caveats
    <<~EOS
      The app bundle is installed at:
        #{prefix}/Dumptruck.app

      Copy it into Applications with:
        cp -R "#{prefix}/Dumptruck.app" /Applications/

      Proprietary SDK helpers are excluded from this open source package.
      FFmpeg and Python are installed separately through Homebrew.

      Dumptruck.app is locally signed. make_app.sh uses "Dumptruck Local Signing" when available and otherwise uses an ad-hoc signature.
    EOS
  end

  test do
    assert_match "dumptruck 0.5.6 (protocol 3)", shell_output("#{bin}/dumptruck --version")
    assert_equal libexec.to_s,
                 (prefix/"Dumptruck.app/Contents/Resources/engine_root.txt").read.strip
  end
end
