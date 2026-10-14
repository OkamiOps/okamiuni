# Layout do instalador (.dmg) do OkamiUNI, lido pelo dmgbuild.
#
# Uso (o Tools/publicar-release.sh faz isto):
#   dmgbuild -s Tools/dmg/settings.py -D app=/caminho/OkamiUNI.app \
#            -D fundo=/pasta/fundo.png "OkamiUNI" saida.dmg
#
# As posições dos ícones têm de bater com `centroApp` e `centroAplicativos`
# em Tools/dmg/fundo.swift, que desenha a seta entre eles.

import os.path

app = defines["app"]  # noqa: F821 — o dmgbuild injeta `defines`
nome_app = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}

background = defines["fundo"]  # noqa: F821
# Altura = fundo (400) + barra de título (28). O y conta de baixo da tela.
window_rect = ((200, 360), (640, 428))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
icon_locations = {
    nome_app: (170, 214),
    "Applications": (470, 214),
}
