# Dr. Kynox iOS App

Bu repo iOS uygulamasi icin duzenlenmistir. Web frontend ve Node/Vercel dosyalari kaldirilmistir.

## Proje Yapisi

- `ios-native/MedCaseAI/MedCaseAI.xcodeproj`: SwiftUI iOS uygulamasi
- `ios-native/MedCaseAI/DrKynoxWidgets`: Widget target
- `supabase/*.sql`: Supabase tablo/RLS kurulum scriptleri

## Xcode ile Calistirma

1. Xcode ile `ios-native/MedCaseAI/MedCaseAI.xcodeproj` ac.
2. `MedCaseAI` target icin Team/Signing ayarlarini yap.
3. Gerekli `Info.plist` ortam alanlarini (backend URL vb.) kendi ortaminda ayarla.
4. Simulator veya cihazda calistir.

## Guvenlik

- `.env` git tarafinda ignore edilir ve bu repoda track edilmez.
- Secret/API key dosyalarini commitleme.
- Public repoya push etmeden once local gizli dosyalari kontrol et.

## Not

Bu repo artik iOS odakli tutulur. Web/backend katmani icin ayri repo kullanilmalidir.
