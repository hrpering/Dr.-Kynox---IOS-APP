# Dr.Kynox Remotion Assets

Bu klasör onboarding/welcome için kısa ve uzun motion intro üretimi içindir.

## Kurulum

```bash
cd tools/remotion
npm install
```

## Render

```bash
npm run render:short
npm run render:long
```

Not: Stabil render için komutlar yerel Chrome yürütücüsü ve tek iş parçacığı (`--concurrency=1`) ile çalıştırılır.

Çıktılar doğrudan iOS bundle yoluna yazılır:
- `ios-native/MedCaseAI/MedCaseAI/Media/intro_short.mp4`
- `ios-native/MedCaseAI/MedCaseAI/Media/intro_long.mp4`

Mobil için optimize ayarlar:
- H264
- CRF 30
- YUV420p
- Sessiz (muted)
