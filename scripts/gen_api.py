"""Write docs/api.html from each package's interface file and the `///`
comments in its sources, so the reference follows the code.

Usage: python scripts/gen_api.py [--check]
"""

from __future__ import annotations

import html
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

PACKAGES = [
    (
        "moonbitstack/moonstate",
        "src",
        "The graph, its builder, the steps a node returns, the two contracts a store or a "
        "saver implements, and the in-memory implementations that ship with them.",
    ),
    (
        "moonbitstack/moonstate/sql",
        "src/sql",
        "Checkpoints and long-term memory on a SQL backend: one implementation, written "
        "against the dialect the driver reports.",
    ),
    (
        "moonbitstack/moonstate/otel",
        "src/otel",
        "An executor that reports each superstep and each node inside it as a span.",
    ),
]

DECL = re.compile(
    r"^pub(?:\((?:all|open)\))?\s+(fn(?:\[[^\]]*\])?|let|struct|enum|suberror|trait|type)\s+([A-Za-z_][\w]*(?:::[A-Za-z_][\w]*)?)"
)


def docs_of(folder: str) -> dict[str, str]:
    """Doc comments by declared name, and by `Type.field` for fields and variants."""
    out: dict[str, str] = {}
    for path in sorted((ROOT / folder).glob("*.mbt")):
        if path.name.endswith("_test.mbt") or path.name.endswith("_wbtest.mbt"):
            continue
        lines = path.read_text(encoding="utf-8").splitlines()
        pending: list[str] = []
        owner = None
        for line in lines:
            stripped = line.strip()
            if stripped == "///|":
                pending = []
                continue
            if stripped.startswith("///"):
                pending.append(stripped[3:].strip())
                continue
            if stripped.startswith("#"):
                continue
            match = DECL.match(line)
            if match:
                name = match.group(2)
                if pending:
                    out[name] = " ".join(pending)
                owner = (
                    name
                    if match.group(1) in ("struct", "enum", "suberror", "trait")
                    and line.rstrip().endswith("{")
                    else None
                )
                pending = []
                continue
            if owner and line.startswith("}"):
                owner = None
            elif owner and pending:
                field = re.match(r"\s+(?:fn\s+)?(?:mut\s+)?([A-Za-z_]\w*)", line)
                if field:
                    out[owner + "." + field.group(1)] = " ".join(pending)
            pending = []
    return out


def items_of(folder: str) -> list[tuple[str, str, str, str | None]]:
    """Declarations from the interface file: (kind, name, text, owner)."""
    text = (ROOT / folder / "pkg.generated.mbti").read_text(encoding="utf-8").splitlines()
    items: list[tuple[str, str, str, str | None]] = []
    block = None
    for line in text:
        if block is not None:
            block[2].append(line)
            if line.startswith("}"):
                items.append((block[0], block[1], "\n".join(block[2]), None))
                block = None
            continue
        if not line.startswith("pub"):
            continue
        match = re.match(r"pub(?:\((?:all|open)\))?\s+(struct|enum|suberror|trait)\s+(\w+)", line)
        if match and line.rstrip().endswith("{"):
            block = [match.group(1), match.group(2), [line]]
            continue
        if match:
            items.append((match.group(1), match.group(2), line, None))
            continue
        match = re.match(r"pub fn(?:\[[^\]]*\])?\s+(\w+)::(\w+)", line)
        if match:
            items.append(("method", match.group(1) + "::" + match.group(2), line, match.group(1)))
            continue
        match = re.match(r"pub fn(?:\[[^\]]*\])?\s+(\w+)", line)
        if match:
            items.append(("fn", match.group(1), line, None))
            continue
        match = re.match(r"pub let (\w+)", line)
        if match:
            items.append(("let", match.group(1), line, None))
            continue
        match = re.match(r"pub type (\w+)", line)
        if match:
            items.append(("type", match.group(1), line, None))
            continue
        match = re.match(r"pub using @(\w+) \{(.*)\}", line)
        if match:
            items.append(("using", match.group(1), line, None))
    return items


def code(text: str) -> str:
    return '<pre class="sig"><code>%s</code></pre>' % html.escape(text.strip())


def prose(text: str) -> str:
    if not text:
        return ""
    escaped = html.escape(text)
    escaped = re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)
    return "<p>%s</p>" % escaped


def anchor(pkg: str, name: str) -> str:
    return (pkg.split("/")[-1] + "-" + name).replace("::", "-").lower()


def render() -> str:
    nav: list[str] = []
    body: list[str] = []
    for pkg, folder, intro in PACKAGES:
        docs = docs_of(folder)
        items = items_of(folder)
        short = pkg.split("/", 1)[1]
        nav.append('<div class="group"><b>%s</b>' % html.escape(short))
        body.append(
            '<section id="%s"><h2><span class="pkg">%s</span></h2>%s'
            % (anchor(pkg, "top"), html.escape(short), prose(intro))
        )
        types = [item for item in items if item[0] in ("struct", "enum", "suberror", "trait", "type")]
        methods: dict[str, list[tuple[str, str]]] = {}
        for kind, name, text, owner in items:
            if kind == "method" and owner:
                methods.setdefault(owner, []).append((name, text))
        values = [item for item in items if item[0] == "let"]
        fns = [item for item in items if item[0] == "fn"]
        usings = [item for item in items if item[0] == "using"]
        if usings:
            body.append("<h3>Re-exported</h3>")
            body.append(prose("Reachable from this package as well; each is documented where it is declared."))
            body.append(code("\n".join(text for _, _, text, _ in usings)))
        for kind, name, text, _ in types:
            nav.append('<a href="#%s">%s</a>' % (anchor(pkg, name), html.escape(name)))
            body.append(
                '<article id="%s"><h3><span class="kind">%s</span> %s</h3>'
                % (anchor(pkg, name), kind, html.escape(name))
            )
            body.append(prose(docs.get(name, "")))
            body.append(code(text))
            fields = [(key.split(".", 1)[1], value) for key, value in docs.items() if key.startswith(name + ".")]
            if fields:
                body.append(
                    '<dl class="fields">%s</dl>'
                    % "".join(
                        "<dt><code>%s</code></dt><dd>%s</dd>" % (html.escape(field), prose(doc))
                        for field, doc in fields
                    )
                )
            for method_name, method_text in methods.get(name, []):
                if re.search(r"::(equal|not_equal|output|to_string|to_repr|hash|hash_combine|compare|op_\w+)\(", method_text):
                    continue
                body.append(
                    '<div class="member" id="%s">%s%s</div>'
                    % (anchor(pkg, method_name), code(method_text), prose(docs.get(method_name, "")))
                )
            body.append("</article>")
        if fns:
            nav.append('<a href="#%s">Functions</a>' % anchor(pkg, "functions"))
            body.append('<h3 id="%s">Functions</h3>' % anchor(pkg, "functions"))
            for _, name, text, _ in fns:
                body.append(
                    '<div class="member" id="%s">%s%s</div>'
                    % (anchor(pkg, name), code(text), prose(docs.get(name, "")))
                )
        if values:
            nav.append('<a href="#%s">Values</a>' % anchor(pkg, "values"))
            body.append('<h3 id="%s">Values</h3>' % anchor(pkg, "values"))
            for _, name, text, _ in values:
                body.append(
                    '<div class="member" id="%s">%s%s</div>'
                    % (anchor(pkg, name), code(text), prose(docs.get(name, "")))
                )
        nav.append("</div>")
        body.append("</section>")
    page = (ROOT / "docs" / "api.template.html").read_text(encoding="utf-8")
    page = page.replace("<!-- nav -->", "\n".join(nav)).replace("<!-- body -->", "\n".join(body))
    return page


def main() -> int:
    page = render()
    target = ROOT / "docs" / "api.html"
    if "--check" in sys.argv:
        if not target.exists() or target.read_text(encoding="utf-8") != page:
            print("docs/api.html is out of date: run python scripts/gen_api.py")
            return 1
        print("docs/api.html matches the sources")
        return 0
    target.write_text(page, encoding="utf-8", newline="\n")
    print("wrote docs/api.html")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
