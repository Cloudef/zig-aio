{
  description = "Zig project flake";

  inputs = {
    zig2nix.url = "github:Cloudef/zig2nix";
  };

  outputs = { zig2nix, ... }: let
    flake-utils = zig2nix.inputs.flake-utils;
  in (flake-utils.lib.eachDefaultSystem (system: let
      # Zig flake helper
      # Check the flake.nix in zig2nix project for more options:
      # <https://github.com/Cloudef/zig2nix/blob/master/flake.nix>
      env = zig2nix.outputs.zig-env.${system} {
        zig = zig2nix.outputs.packages.${system}.zig.master.bin;
      };
    in with builtins; with env.lib; with env.pkgs.lib; {
      # nix run .
      apps.default = env.app [] "zig build example -- \"$@\"";

      # nix run .#build
      apps.build = env.app [] "zig build \"$@\"";

      # nix run .#test
      apps.test = with env.pkgs; env.app [wasmtime] ''
        zig version
        if [[ "$(uname)" == "Linux" ]]; then
          echo "zig build test bug -Daio:posix=disable -Dsanitize=true"
          zig build test bug -Daio:posix=disable -Dsanitize=true
          echo "zig build test bug -Daio:posix=force -Dsanitize=true"
          zig build test bug -Daio:posix=force -Dsanitize=true
          echo "zig build test bug -Daio:posix=force -Dminilib:force_foreign_timer_queue=true -Dsanitize=true"
          zig build test bug -Daio:posix=force -Dminilib:force_foreign_timer_queue=true -Dsanitize=true
          echo "zig build test:aio test:minilib -Dtarget=wasm32-wasi-none"
          zig build -Doptimize=ReleaseSafe test:aio test:minilib -Dtarget=wasm32-wasi-none
        elif [[ "$(uname)" == "Darwin" ]]; then
          echo "zig build test bug"
          zig build test bug
          echo "zig build test bug -Dtarget=x86_64-macos"
          zig build test bug -Dtarget=x86_64-macos
        else
          echo "zig build test bug"
          zig build test bug
        fi
      '';

      # nix run .#check
      apps.check = env.app [] ''
        echo "checking the formatting with zig fmt --check"
        zig fmt --check .
      '';

      # nix run .#deps
      apps.deps = env.showExternalDeps;

      # nix run .#zon2json
      apps.zon2json = env.app [env.zon2json] "zon2json \"$@\"";

      # nix run .#zon2json-lock
      apps.zon2json-lock = env.app [env.zon2json-lock] "zon2json-lock \"$@\"";

      # nix run .#zon2nix
      apps.zon2nix = env.app [env.zon2nix] "zon2nix \"$@\"";

      # nix develop
      devShells.default = env.mkShell {
          nativeBuildInputs = with env.pkgs; [wasmtime wineWowPackages.minimal];
      };

      # nix run .#readme
      apps.readme = env.app [] (builtins.replaceStrings ["`"] ["\\`"] ''
      cat <<EOF
      # zig-aio

      zig-aio provides io_uring like asynchronous API and coroutine powered IO tasks for zig

      * [Documentation](https://cloudef.github.io/zig-aio)

      ---

      [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

      Project is tested on zig version $(zig version)

      ## Support matrix

      | OS      | AIO             | CORO            |
      |---------|-----------------|-----------------|
      | Linux   | io_uring, posix | x86_64, aarch64 |
      | Windows | iocp            | x86_64, aarch64 |
      | Darwin  | posix           | x86_64, aarch64 |
      | *BSD    | posix           | x86_64, aarch64 |
      | WASI    | posix           | ❌              |

      * io_uring AIO backend is very light wrapper, where all the code does is mostly error mapping
      * iocp also maps quite well to the io_uring style API
      * posix backend is for compatibility, it may not be very effecient
      * WASI may eventually get coro support [Stack Switching Proposal](https://github.com/WebAssembly/stack-switching/blob/main/proposals/stack-switching/Explainer.md)

      ## Example

      ```zig
      $(cat examples/coro.zig)
      ```

      ## Perf

      `strace -c` output from the `examples/coro.zig` without `std.log` output and with `std.heap.FixedBufferAllocator`.
      This is using the `io_uring` backend. `posix` backend emulates `io_uring` like interface by using a traditional
      readiness event loop, thus it will have larger syscall overhead.

      ```
      % time     seconds  usecs/call     calls    errors syscall
      ------ ----------- ----------- --------- --------- ------------------
        0.00    0.000000           0         2           close
        0.00    0.000000           0         4           mmap
        0.00    0.000000           0         4           munmap
        0.00    0.000000           0         5           rt_sigaction
        0.00    0.000000           0         1           bind
        0.00    0.000000           0         1           listen
        0.00    0.000000           0         2           setsockopt
        0.00    0.000000           0         1           execve
        0.00    0.000000           0         1           arch_prctl
        0.00    0.000000           0         1           gettid
        0.00    0.000000           0         2           prlimit64
        0.00    0.000000           0         2           io_uring_setup
        0.00    0.000000           0         6           io_uring_enter
        0.00    0.000000           0         1           io_uring_register
      ------ ----------- ----------- --------- --------- ------------------
      100.00    0.000000           0        33           total
      ```
      EOF
      '');
    }));
}
