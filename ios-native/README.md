# MedCaseAI Native iOS (SwiftUI)

Bu klasor, uygulamanin SwiftUI tabanli iOS surumunu icerir.

## Xcode ile ac

1. `ios-native/MedCaseAI/MedCaseAI.xcodeproj` dosyasini ac.
2. `Signing & Capabilities` altinda Team sec.
3. `Info.plist` icindeki `BACKEND_BASE_URL` degerini backend URL'inle dogrula.

## Paket bagimliliklari

Proje Swift Package Manager ile iki paket kullanir:

- `supabase-swift` (auth + db sorgulari)
- `elevenlabs-swift-sdk` (voice/text agent oturumu)

Xcode acildiginda paketler otomatik resolve edilir.

## Mimari

- **Supabase Auth + DB**: `SupabaseService.swift`
  - `profiles`, `case_sessions`, `daily_challenges` tablolarina mevcut schema ile yazar/okur.
  - Yeni tablo veya endpoint acmaz.
  - `daily_challenges` aktif kayit yoksa, backenddeki mevcut LLM uretim akisina (`/api/challenge/today`) bir kez tetik atip tabloyu yeniden okur.
- **Backend proxy**: `APIClient.swift`
  - `/api/elevenlabs/session-auth`
  - `/api/score`
- **Agent oturumu**: `AgentConversationViewModel.swift`
  - Agent dynamic variables gonderir.
  - Text/voice transcript akisini toplar.

## Test checklist (manuel)

1. **Session persist**
   - Giris yap -> app'i kapat/ac -> oturumun korunmasini kontrol et.
2. **Mikrofon izni (voice)**
   - Voice vaka baslat -> mikrofon iznini ver -> basili tut-konuş akisini kontrol et.
3. **Realtime mesaj akisi**
   - Agent yanitlarinin chat'e anlik dusmesini kontrol et.
4. **Vaka bitis akisi**
   - Vakayi bitir -> sonuc ekranina gec -> skor olusunca kayit ve gecmiste gorunme.

## Not

Bu sandbox ortaminda `xcodebuild` ve package resolve izinleri kisitli oldugu icin cihaz/simulator derlemesi burada dogrulanamadi. Kod akisi bu nedenle yerel Xcode ortaminda test edilmelidir.
