// mer-shell.js — SSR-shell client-side navigation.
//
// Progressive enhancement, not a client-side router: the server still
// renders every page (SSR is the source of truth). This script only
// avoids full page reloads on same-origin link clicks by fetching the
// next page's fragment and swapping it into the mount element.
//
// Opt-in, degrades safely:
//   - No `#mer-shell` element on the page  -> script does nothing.
//   - Non-JSON response (e.g. a prerendered/static page) -> full navigation.
//   - Any fetch/network error               -> full navigation.
//
// Server contract: a GET request with header `X-Mer-Shell: 1` gets back
// `{"title": "...", "body": "...html fragment..."}` instead of the full
// document (see src/server.zig / src/dispatch.zig `dispatchFragment`).
(function () {
  var mount = document.getElementById("mer-shell");
  if (!mount) return;

  function sameOrigin(url) {
    try {
      return new URL(url, location.href).origin === location.origin;
    } catch (e) {
      return false;
    }
  }

  function isShellLink(a) {
    if (!a || !a.href) return false;
    if (a.target === "_blank" || a.hasAttribute("download")) return false;
    if (a.hasAttribute("data-mer-reload")) return false;
    if (a.getAttribute("href").indexOf("#") === 0) return false;
    return sameOrigin(a.href);
  }

  function setLoading(on) {
    document.documentElement.classList.toggle("mer-shell-loading", on);
  }

  function navigate(url, push) {
    setLoading(true);
    fetch(url, {
      headers: { "X-Mer-Shell": "1" },
      credentials: "same-origin",
    })
      .then(function (res) {
        var ct = res.headers.get("content-type") || "";
        if (ct.indexOf("application/json") === -1) {
          // Not a shell-aware response (e.g. prerendered HTML) — bail out
          // to a real navigation so the user still gets the right page.
          location.href = url;
          return null;
        }
        return res.json();
      })
      .then(function (data) {
        if (!data) return;
        mount.innerHTML = data.body;
        if (data.title) document.title = data.title;
        if (push) history.pushState({ merShell: true }, "", url);
        window.scrollTo(0, 0);
        document.dispatchEvent(
          new CustomEvent("mer:navigate", { detail: { url: url } })
        );
      })
      .catch(function () {
        location.href = url;
      })
      .finally(function () {
        setLoading(false);
      });
  }

  document.addEventListener("click", function (e) {
    if (
      e.defaultPrevented ||
      e.button !== 0 ||
      e.metaKey ||
      e.ctrlKey ||
      e.shiftKey ||
      e.altKey
    )
      return;
    var a = e.target.closest ? e.target.closest("a[href]") : null;
    if (!isShellLink(a)) return;
    e.preventDefault();
    navigate(a.href, true);
  });

  window.addEventListener("popstate", function () {
    navigate(location.href, false);
  });
})();
