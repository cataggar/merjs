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
HOT_RELOAD_MARKER = b'<script id="__mer_hr__">'


def run(*args, cwd=ROOT):
    result = subprocess.run(args, cwd=cwd, text=True, encoding="utf-8", stdout=subprocess.PIPE,
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
def server(binary, cwd, *, dev=False):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    args = [str(binary), "--host", "127.0.0.1", "--port", str(port)]
    if not dev:
        args.append("--no-dev")
    env = os.environ.copy()
    env["MERJS_DEV"] = "1" if dev else "0"
    with tempfile.TemporaryFile(mode="w+t", encoding="utf-8", dir=ROOT) as log:
        process = subprocess.Popen(
            args, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT)
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
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)


def check_scaffold(source):
    run("zig", "build", "cli", "-Doptimize=safe", f"-Dmerjs-url={source}")
    cli = ROOT / "zig-out" / "bin" / f"mer{SUFFIX}"
    with tempfile.TemporaryDirectory(prefix="merjs-scaffold-", dir=ROOT) as temporary:
        app = pathlib.Path(temporary) / "app"
        run(str(cli), "init", str(app))
        manifest = app / "build.zig.zon"
        assert source in manifest.read_text(encoding="utf-8")
        assert manifest.read_text(encoding="utf-8").count(".hash =") == 1
        previous_source = "git+https://github.com/cataggar/merjs.git#23dcf37a471d83469bd2d705f007aea51ceed953"
        previous_hash = "merjs-0.2.5-qL9Lkg3JYABh2AupQ9X64qsQ-bNQLv5SSGnHVtb2j9UR"
        text = manifest.read_text(encoding="utf-8").replace(source, previous_source)
        hash_start = text.index('.hash = "') + len('.hash = "')
        hash_end = text.index('"', hash_start)
        manifest.write_text(text[:hash_start] + previous_hash + text[hash_end:], encoding="utf-8")
        run(str(cli), "update", cwd=app)
        assert source in manifest.read_text(encoding="utf-8")
        assert previous_source not in manifest.read_text(encoding="utf-8")
        assert previous_hash not in manifest.read_text(encoding="utf-8")
        assert manifest.read_text(encoding="utf-8").count(".hash =") == 1
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
            '}\n', encoding="utf-8")
        run("zig", "build", cwd=app)
        assert '"/nested/:id"' in generated.read_text(encoding="utf-8")
        assert '@import("app/nested/[id]")' in generated.read_text(encoding="utf-8")
        with server(binary, app) as base:
            status, _, body = request(base, "/nested/42")
            assert status == 200 and b"nested-route" in body

        page = page.rename(nested / "renamed.zig")
        run("zig", "build", cwd=app)
        assert '"/nested/:id"' not in generated.read_text(encoding="utf-8")
        assert '"/nested/renamed"' in generated.read_text(encoding="utf-8")
        with server(binary, app) as base:
            assert request(base, "/nested/renamed")[0] == 200

        page.unlink()
        run("zig", "build", cwd=app)
        assert '"/nested/renamed"' not in generated.read_text(encoding="utf-8")
        api = app / "api"
        hello = api / "hello.zig"
        hello_source = hello.read_text(encoding="utf-8")
        hello.unlink()
        api.rmdir()
        run("zig", "build", cwd=app)
        assert '"/api/hello"' not in generated.read_text(encoding="utf-8")
        api.mkdir()
        hello.write_text(hello_source, encoding="utf-8")
        run("zig", "build", cwd=app)
        assert '"/api/hello"' in generated.read_text(encoding="utf-8")
        with server(binary, app) as base:
            assert request(base, "/nested/renamed")[0] == 404
            status, headers, body = request(base, "/")
            assert status == 200 and b"<!DOCTYPE" in body
            assert "https://github.com" in headers["Content-Security-Policy"]
            assert "https://*.githubusercontent.com" in headers["Content-Security-Policy"]
    print("scaffold, update, production, nested routes and cache invalidation: passed")


def check_markup(base, path, content, minimum_size, *, streaming, dev):
    status, headers, body = request(base, path)
    label = f"{path} ({'dev' if dev else 'production'})"
    assert status == 200, f"{label}: status {status}"
    assert headers.get_content_type() == "text/html", f"{label}: {headers}"
    assert len(body) >= minimum_size, f"{label}: truncated HTML ({len(body)} bytes)"
    assert body.startswith(b"<!DOCTYPE html>"), f"{label}: missing document head"
    assert body.rstrip().endswith(b"</html>"), f"{label}: missing document tail"
    assert body.count(b"</body>") == 1, f"{label}: </body> count: {body.count(b'</body>')}"
    assert body.count(b"</html>") == 1, f"{label}: duplicate html closer"
    content_start = body.index(content)
    body_end = body.index(b"</body>")
    assert body.index(b"<body>") < content_start < body_end < body.index(b"</html>"), label
    if streaming:
        assert headers.get("Transfer-Encoding") == "chunked", f"{label}: not streaming"
        footer_start = body.index(b'<footer class="layout-footer">')
        footer_end = body.index(b"</footer>", footer_start) + len(b"</footer>")
        assert content_start < footer_start < footer_end < body_end, label
    else:
        assert int(headers["Content-Length"]) == len(body), f"{label}: body length"
    if not dev:
        assert HOT_RELOAD_MARKER not in body, f"{label}: injected hot reload"
        return body, None

    assert body.count(HOT_RELOAD_MARKER) == 1, f"{label}: hot reload script count"
    script_start = body.index(HOT_RELOAD_MARKER)
    script_end = body.index(b"</script>", script_start) + len(b"</script>")
    assert content_start < script_start < script_end < body_end, label
    if streaming:
        assert script_end < footer_start, f"{label}: script must precede layout footer"
    return body, body[script_start:script_end]


def check_hot_reload(binary):
    routes = (
        ("/docs", b'<section id="deploy">', 18000, True),
        ("/counter", b'id="count-value"', 8000, True),
        ("/desktop", b"<h1>desktop.zig</h1>", 7000, False),
    )
    dev_responses = {}
    with server(binary, ROOT, dev=True) as base:
        for path, content, minimum_size, streaming in routes:
            dev_responses[path] = check_markup(
                base, path, content, minimum_size, streaming=streaming, dev=True)
    script = dev_responses["/docs"][1]
    assert len(script) > 4000, "expected the complete morphing hot-reload script"
    assert all(payload == script for _, payload in dev_responses.values()), (
        "streaming and replacement injection must use the same complete script")
    with server(binary, ROOT) as base:
        for path, content, minimum_size, streaming in routes:
            production, _ = check_markup(
                base, path, content, minimum_size, streaming=streaming, dev=False)
            injection = script if streaming else script + b"\n"
            assert dev_responses[path][0].replace(injection, b"", 1) == production, (
                f"{path}: production differs beyond hot-reload injection")
            print(f"{path}: dev {len(dev_responses[path][0])} bytes, "
                  f"production {len(production)} bytes; one body closer, "
                  "ordered markup, identical bytes after removing injection")
    print(f"dev/production renderStream, shell-first and full-document markup: passed "
          f"(identical {len(script)}-byte hot-reload script)")


def check_demo():
    run("zig", "build", "-j2")
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
    check_hot_reload(binary)


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
    parser.add_argument("--source")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--assets", action="store_true")
    modes.add_argument("--runtime-only", action="store_true",
                       help="check real demo HTTP responses without scaffolding or downloads")
    args = parser.parse_args()
    if not args.runtime_only and not args.source:
        parser.error("--source is required unless --runtime-only is selected")
    if args.assets:
        check_assets()
    elif args.runtime_only:
        check_demo()
    else:
        check_scaffold(args.source)
        check_demo()


if __name__ == "__main__":
    main()
