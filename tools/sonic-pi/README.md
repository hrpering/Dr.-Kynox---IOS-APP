# Dr.Kynox Sonic Pi Sound Design

Bu klasörde UI sesleri ve ambient için Sonic Pi kaynak kodu bulunur.

Dosya:
- `drkynox_ui_sfx.rb`

## Önerilen export akışı
1. Sonic Pi'da `drkynox_ui_sfx.rb` aç.
2. İlgili fonksiyonu solo çalıştır (`ui_tap`, `ui_success`, `ui_error`, `ambient_bed`).
3. Çıktıyı WAV olarak kaydet.
4. iOS bundle içindeki dosyaları güncelle:
   - `ios-native/MedCaseAI/MedCaseAI/Media/Sounds/ui_tap.wav`
   - `ios-native/MedCaseAI/MedCaseAI/Media/Sounds/ui_success.wav`
   - `ios-native/MedCaseAI/MedCaseAI/Media/Sounds/ui_error.wav`
   - `ios-native/MedCaseAI/MedCaseAI/Media/Sounds/ambient_bed.wav`

Not: Uygulama şu an bu dört dosyayı otomatik yükleyip çalar.
