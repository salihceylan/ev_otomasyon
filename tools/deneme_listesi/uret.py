"""Deneme listesi sayfalarini uretir: sablon.html + <rol>.json -> <rol>.html. Kullanim: python uret.py [rol ...]"""
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROLLER = {
    "super": ("Süper Kullanıcı Deneme Listesi", "#3451c7", "#dde4fb", "#8ea2ff", "#25305a"),
    "servis": ("Servis Sorumlusu Deneme Listesi", "#c2410c", "#fde5d6", "#ff9a5c", "#4a2716"),
    "daire": ("Daire Kullanıcısı Deneme Listesi", "#0b7a75", "#d5efed", "#4fd1c5", "#14403d"),
}

sablon = io.open(os.path.join(HERE, "sablon.html"), encoding="utf-8").read()
for rol in sys.argv[1:] or list(ROLLER):
    title, acc, soft, acc_d, soft_d = ROLLER[rol]
    veri = json.load(io.open(os.path.join(HERE, rol + ".json"), encoding="utf-8"))
    ids = [m["id"] for b in veri["bolumler"] for m in b["maddeler"]]
    assert len(ids) == len(set(ids)), "yinelenen madde id"
    veri["rol"] = rol
    data = json.dumps(veri, ensure_ascii=False).replace("</", "<\\/")
    html = (sablon.replace("__TITLE__", title).replace("__ACCENT__", acc).replace("__ACCENT_SOFT__", soft)
            .replace("__ACCENT_DARK__", acc_d).replace("__ACCENT_SOFT_DARK__", soft_d).replace("__DATA__", data))
    io.open(os.path.join(HERE, rol + ".html"), "w", encoding="utf-8", newline="\n").write(html)
    print(rol, "bolum", len(veri["bolumler"]), "madde", len(ids), "->", rol + ".html", len(html), "bayt")
