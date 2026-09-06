# Classificação das 25 fontes por orientação nativa
# (base para o motor v3 — nada aqui vira tarja com borrão)

## DEITADAS (14) -> só render 16x9  [monitor DP-2, 1920x1080]
extra-b-wallpapercave-stoner-03.jpg      1920x1080  1.78
google-cosmic-portal-02.jpg              1920x1080  1.78
google-minimalist-redcircle-03.jpg       1920x1080  1.78   (v2 não renderizou)
google-starfield-dark-04.jpg             1920x1080  1.78   (v2 não renderizou)
paisagem-eyepatch-black-04.jpg           1920x1080  1.78
paisagem-minimalista-black-01.jpg        1920x1080  1.78   (v2 não renderizou)
paisagem-portal-verde-02.png             1920x1080  1.78   (v2 não renderizou)
extra-b-rixwn-space-02.jpg               3440x1440  2.39   ultrawide: crop lateral leve
user-img6-02-upscaled.png                3600x2024  1.78
paisagem-garagem-noturna-03.jpg          3812x2144  1.78
unico-b-rick-minimalista.png             4096x2160  1.90
unico-b-rick-amoled-5120.png             5120x2880  1.78
user-img2-upscaled.png                   6784x3904  1.74
unico-b-rick-morty-battle-dark-8000.png  8000x4500  1.78

## EM PÉ (9) -> só render 9x16  [monitor HDMI-A-1, 1080x1920]
retrato-rick-amoled-02.jpg               1080x1920  0.56
retrato-rick-morty-season8-portal-03.jpg 1080x1920  0.56
google-portal-silhouette-01.jpg          1159x1920  0.60
retrato-rick-amoled-01.png               1440x2560  0.56   (v2 não renderizou)
user-img1-upscaled.png                   1656x3628  0.46   mais alta que 9:16: crop topo/base
user-img4-upscaled.png                   1664x2980  0.56
user-img6-01-upscaled.png                3200x5688  0.56
user-img9-upscaled.png                   3744x6768  0.55
user-img5-upscaled.png                   4144x8160  0.51

## QUASE QUADRADAS (2) -> caso a caso
user-img7-upscaled.png                   1672x2224  0.75  -> 9x16 (fit vertical, sobra pouca)
user-img10-upscaled.png                  3452x2348  1.47  -> 16x9 (cover, perda pequena)

## Saldo
16x9: 15 wallpapers   |   9x16: 10 wallpapers
Nenhum precisa de fit+blur. Zero tarja.

## Correções que a v3 leva além da classificação
1. Motivo minúsculo no preto (user-img1, google-minimalist-redcircle, "Wubba Lubba"):
   render_flat com fill baixo demais. Subir fill p/ 0.85-0.92 nos AMOLED de motivo pequeno.
2. Saída continua PNG (evita banding JPEG no preto AMOLED).
3. Upscale: Real-ESRGAN x4plus-anime SEMPRE -s 4 (escala fixa; -s 2/-s 3 corrompe em silêncio).
4. Ferramentas confirmadas nesta máquina: liblqr 0.4.3 ativo (-liquid-rescale funciona),
   opencv 5.0.0 instalado. Reframe por saliência/seam carving não exige instalar nada —
   fica como plano B se alguma arte deitada específica for indispensável no monitor vertical.
