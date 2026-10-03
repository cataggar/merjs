import argparse
import contextlib
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[1]
SUFFIX = ".exe" if os.name == "nt" else ""


def run(*args, cwd=ROOT):
    result = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    if result.returncode:
        print(result.stdout, flush=True)
        raise subprocess.CalledProcessError(result.returncode, args)
    return result.stdout


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request(base, path):
    opener = urllib.request.build_opener(NoRedirect)
    try:
        response = opener.open(base + path, timeout=3)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.headers, response.read()


@contextlib.contextmanager
def server(binary, cwd):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    with tempfile.TemporaryFile(mode="w+t") as log:
        process = subprocess.Popen(
            [str(binary), "--no-dev", "--host", "127.0.0.1", "--port", str(port)],
            cwd=cwd, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 15
            while True:
                if process.poll() is not None:
                    raise RuntimeError("server exited before becoming ready")
                try:
                    status, _, _ = request(base, "/_mer/health")
                    if status == 200:
                        break
                except (urllib.error.URLError, TimeoutError, ConnectionError):
                    pass
                if time.monotonic() >= deadline:
                    raise TimeoutError("server did not become ready")
                time.sleep(0.1)
            yield base
        except BaseException:
            log.seek(0)
            print(log.read(), flush=True)
            raise
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=10)


def check_scaffold(source):
    run("zig", "build", "cli", "-Doptimize=safe", f"-Dmerjs-url={source}")
    cli = ROOT / "zig-out" / "bin" / f"mer{SUFFIX}"
    with tempfile.TemporaryDirectory(prefix="merjs-scaffold-") as temporary:
        app = pathlib.Path(temporary) / "app"
        run(str(cli), "init", str(app))
        manifest = app / "build.zig.zon"
        assert source in manifest.read_text()
        assert manifest.read_text().count(".hash =") == 1
        run(str(cli), "update", cwd=app)
        assert source in manifest.read_text()
        assert manifest.read_text().count(".hash =") == 1
        run("zig", "build", "test", cwd=app)
        run(str(cli), "build", cwd=app)
        binary = app / "zig-out" / "bin" / f"app{SUFFIX}"
        generated = app / "src" / "generated" / "routes.zig"

        nested = app / "app" / "nested"
        nested.mkdir()
        page = nested / "[id].zig"
        page.write_text(
            'const mer = @import("mer");\n'
            'pub const meta: mer.Meta = .{ .title = "Cache fixture" };\n'
            'pub fn render(_: mer.Request) mer.Response {\n'
            '    return mer.html("<h1>nested-route</h1>");\n'
            '}\n')
        run("zig", "build", cwd=app)
        assert '"/nested/:id"' in generated.read_text()
        assert '@import("app/nested/[id]")' in generated.read_text()
        with server(binary, app) as base:
            status, _, body = request(base, "/nested/42")
            assert status == 200 and b"nested-route" in body

        page = page.rename(nested / "renamed.zig")
        run("zig", "build", cwd=app)
        assert '"/nested/:id"' not in generated.read_text()
        assert '"/nested/renamed"' in generated.read_text()
        with server(binary, app) as base:
            assert request(base, "/nested/renamed")[0] == 200

        page.unlink()
        run("zig", "build", cwd=app)
        assert '"/nested/renamed"' not in generated.read_text()
        api = app / "api"
        hello = api / "hello.zig"
        hello_source = hello.read_text()
        hello.unlink()
        api.rmdir()
        run("zig", "build", cwd=app)
        assert '"/api/hello"' not in generated.read_text()
        api.mkdir()
        hello.write_text(hello_source)
        run("zig", "build", cwd=app)
        assert '"/api/hello"' in generated.read_text()
        with server(binary, app) as base:
            assert request(base, "/nested/renamed")[0] == 404
            status, headers, body = request(base, "/")
            assert status == 200 and b"<!DOCTYPE" in body
            assert "https://github.com" in headers["Content-Security-Policy"]
            assert "https://*.githubusercontent.com" in headers["Content-Security-Policy"]
    print("scaffold, update, production, nested routes and cache invalidation: passed")


def check_demo():
    run("zig", "build")
    binary = ROOT / "zig-out" / "bin" / f"merjs{SUFFIX}"
    with server(binary, ROOT) as base:
        status, _, body = request(base, "/api/hello")
        assert status == 200 and json.loads(body)["zig_version"] == "0.17.0"
        status, headers, _ = request(base, "/admin")
        assert status == 303 and headers["Location"] == "/login"
        first = request(base, "/isr-demo")
        second = request(base, "/isr-demo")
        assert first[0] == second[0] == 200 and first[2] == second[2]
    print("demo API, middleware and ISR: passed")


def check_assets():
    wasm = ROOT / "examples" / "site" / "fastly" / "merjs.wasm"
    sentinel = b"merjs-static-cache-regression-issue-6"
    public = ROOT / "examples" / "site" / "public"
    with tempfile.TemporaryDirectory(prefix="cache-fixture-", dir=public) as temporary:
        directory = pathlib.Path(temporary)
        asset = directory / "before.txt"
        asset.write_bytes(sentinel)
        run("zig", "build", "fastly")
        assert sentinel in wasm.read_bytes()
        asset = asset.rename(directory / "after.txt")
        run("zig", "build", "fastly")
        assert f"/{directory.name}/after.txt".encode() in wasm.read_bytes()
        assert f"/{directory.name}/before.txt".encode() not in wasm.read_bytes()
        asset.unlink()
        run("zig", "build", "fastly")
        assert sentinel not in wasm.read_bytes()
    print("nested static-asset additions, renames and deletions: passed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--assets", action="store_true")
    args = parser.parse_args()
    if args.assets:
        check_assets()
    else:
        check_scaffold(args.source)
        check_demo()


if __name__ == "__main__":
    main()
