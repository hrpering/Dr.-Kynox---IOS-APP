# ElevenLabs Agent SDK + OpenAI Skorlama Uygulamasi

Bu proje, ElevenLabs Agent SDK ile canli konusmadan mesaj kaydi toplar ve medikal rubric'e gore skorlayip geri bildirim uretir. Uygulama Supabase Auth + veritabani entegrasyonu ile welcome, kayit/giris, onboarding, dashboard ve vaka gecmisi akislarini icerir.

## Nasil Calisir

Uygulama onboarding + vaka akisi olarak calisir:

1. `Welcome` (`/`) - karsilama ekrani.
2. `Login` (`/login.html`) ve `Signup` (`/signup.html`) - Supabase Auth ile oturum.
3. Ilk giriste `Onboarding` adimlari:
   - `/onboarding-profile.html`
   - `/onboarding-goal.html`
   - `/onboarding-interests.html`
   - `/onboarding-level.html`
4. `Dashboard` (`/index.html`) - ilerleme, gecmis ve vaka baslatma merkezi.
5. `Random Case Generator` (`/generator.html`) - mode secimi (`voice` veya `text`).
6. `Voice Session` (`/voice.html`) - voice agent ile gorusme.
7. `Text Session` (`/text.html`) - text agent ile yazisma.
8. `Case Results` (`/case-results.html`) - otomatik skor ozeti.
9. `Detailed Feedback` (`/detailed-feedback.html`) - 10 alan icin detayli aciklama ve oneriler.
10. `Case History` (`/case-history.html`) ve `Profile` (`/profile.html`) sayfalari.

Mode secimine gore agent secilir:
- `voice` -> `agent_3701kj62fctpe75v3a0tca39fy26`
- `text` -> `agent_3701kj62fctpe75v3a0tca39fy26`

Case `End` edildiginde skor/feedback otomatik uretilir ve `Case Results` sayfasina gecilir.
`Case Results` icinden `Detailed Feedback` sayfasina gidilir.

## Kurulum

```bash
npm install
cp .env.example .env
```

`.env` icine gerekli anahtarlari ekle:

```bash
OPENAI_API_KEY=...
OPENAI_MODEL=gpt-5-mini
PORT=3000
SUPABASE_URL=...
SUPABASE_ANON_KEY=...
SUPABASE_SERVICE_ROLE_KEY=...
AUTHORIZATION_URL=http://localhost:6000/oauth/consent
AI_FEATURES_ENABLED=true
AI_ADMIN_TOKEN=guclu-bir-admin-token
```

Calistir:

```bash
npm run dev
```

Tarayicida ac:

`http://localhost:3000`

## Native iOS (SwiftUI)

Bu repoda ayrica native iOS proje iskeleti eklendi:

- `ios-native/MedCaseAI/MedCaseAI.xcodeproj`

Acma:

1. Xcode ile `ios-native/MedCaseAI/MedCaseAI.xcodeproj` ac.
2. `MedCaseAI` target'inda `Signing & Capabilities` altinda Team sec.
3. `Info.plist` icindeki `BACKEND_BASE_URL` degeri deploy edilen backend URL'ine ayarli olmali.

Native uygulama su akislari icerir:
- Login / Signup (`supabase-swift`)
- Onboarding (`profiles` tablosu)
- Dashboard (gunluk meydan okuma + istatistik)
- Rastgele vaka uretici (zorluk + bolum + mode secimi)
- Text ve voice case oturumu (ElevenLabs Swift SDK)
- Vaka bitisinde skor/feedback olusturma (`/api/score`) ve kaydetme (`case_sessions`)
- Home Screen + Lock Screen widget (`DrKynoxWidgets`) ile gunun vaka bilgisi

Widget notu:
- Widget backend'den `GET /api/challenge/today` verisini cekerek guncellenir.
- Widget onboarding adimi uygulama icinde ekleme adimlarini kullaniciya anlatir.

Guvenlik modeli:
- OpenAI/ElevenLabs gizli anahtarlari iOS istemcide yok.
- iOS yalnizca backend proxy endpointlerine gider:
  - `POST /api/elevenlabs/session-auth`
  - `POST /api/score`
- Gunluk vaka verisi iOS tarafinda dogrudan Supabase `daily_challenges` tablosundan okunur.
- Supabase tarafinda istemci yalniz `anon` key kullanir; service role sadece backend'de kalir.
- Upstash Redis ile server tarafinda rate-limit sayaçlari, brute-force lock kayitlari,
  tek aktif oturum lock'u ve gecici cache katmani tutulur.

## Supabase Veritabani Notu

Supabase SQL Editor'da su dosyalari sirasiyla calistir:

1. `supabase/profiles.sql`
2. `supabase/case_sessions.sql`
3. `supabase/daily_challenges.sql`
4. `supabase/content_reports.sql`
5. `supabase/user_feedback.sql`
6. `supabase/platform_ops.sql`

Otomatik kurulum secenegi (manual SQL olmadan):

- Admin endpoint: `POST /api/admin/supabase/bootstrap`
- Header: `x-admin-token: <AI_ADMIN_TOKEN>`
- Env:
  - `SUPABASE_MANAGEMENT_TOKEN` (onerilen, Supabase Management API)
  - veya project Data API SQL endpointleri (ortam destekliyorsa) otomatik fallback
- Opsiyonel:
  - `SUPABASE_SCHEMA_AUTO_APPLY=true` yapilirsa server acilisinda schema auto-apply dener.

Ornek cagrı:

```bash
curl -X POST http://localhost:3000/api/admin/supabase/bootstrap \
  -H "Content-Type: application/json" \
  -H "x-admin-token: <AI_ADMIN_TOKEN>" \
  -d '{"engine":"auto"}'
```

Bu SQL'ler sunlari da zorunlu kilar:
- RLS + FORCE RLS (kullanici sadece kendi `profiles` ve `case_sessions` satirlarini gorur).
- `daily_challenge_attempts` ile gunluk vaka cozen sayisi ve ortalama skor güvenilir tutulur.
- `daily_challenges` sadece okunur; yazma sadece backend/service role tarafinda.
- `content_reports` tablosunda kullanici yalnizca kendi raporunu ekler/gorur.
- `user_feedback` tablosunda kullanici yalnizca kendi feedback kaydini ekler/gorur.
- `platform_ops.sql` ile asagidaki tablolar eklenir:
  - `daily_challenge_attempts` (gunluk challenge deneme/score)
  - `app_sessions` (uygulama session telemetri)
  - `scoring_jobs` (scoring audit)
  - `widget_events` (widget olaylari)
  - `gdpr_requests` (KVKK/GDPR talepleri)
  - `rate_limit_audit_events` (rate-limit guvenlik loglari; service-role only)
- Hassas alan korumasi:
  - `profiles`: `ai_enabled`, `ai_disabled_reason`, `ai_disabled_at`, `email`, `id` istemci tarafindan update edilemez.
  - `case_sessions`: `score`, `user_id`, `session_id` istemci tarafindan update edilemez.

## AI Off Switch (Kullanici Bazli)

Kullanici bazli AI kapatma server tarafinda enforce edilir. `profiles.ai_enabled = false` oldugunda:

- `POST /api/elevenlabs/session-auth`
- `POST /api/text-agent/start`
- `POST /api/text-agent/reply`
- `POST /api/score`

istekleri aninda `403` doner.

### Hizli admin endpoint

`POST /api/admin/ai-switch`

Header:

- `x-admin-token: <AI_ADMIN_TOKEN>`

Body ornegi:

```json
{
  "userId": "UUID",
  "enabled": false,
  "reason": "Politika ihlali"
}
```

veya email ile:

```json
{
  "email": "kullanici@example.com",
  "enabled": true
}
```

Notlar:
- `AI_FEATURES_ENABLED=false` yaparsan tum kullanicilar icin global AI kapatilir.
- Bu endpoint sadece backend token ile cagrilmalidir; frontend'e koyma.

## Guvenlik Sertlestirme

- Brute-force lockout aktif:
  - `BRUTE_FORCE_THRESHOLD`
  - `BRUTE_FORCE_WINDOW_MS`
  - `BRUTE_FORCE_BLOCK_MS`
- Global DDoS korumasi (tum `/api` istekleri):
  - `RATE_LIMIT_GLOBAL_TOTAL_PER_MIN` (toplam sistem trafigi)
  - `RATE_LIMIT_GLOBAL_IP_PER_MIN` (IP bazli dakika limiti)
  - `RATE_LIMIT_GLOBAL_TOTAL_PER_10S` (global burst limiti)
  - `RATE_LIMIT_GLOBAL_IP_PER_10S` (IP burst limiti)
  - Toplam istek sayaci Redis'te `metrics:requests:total` anahtarinda tutulur.
- Raporlama rate-limit:
  - `RATE_LIMIT_REPORT_CREATE_IP_PER_MIN`
  - `RATE_LIMIT_REPORT_CREATE_USER_PER_MIN`
- Feedback rate-limit:
  - `RATE_LIMIT_FEEDBACK_CREATE_IP_PER_MIN`
  - `RATE_LIMIT_FEEDBACK_CREATE_USER_PER_MIN`
- `NEXT_PUBLIC_` guvenlik kurali:
  - OpenAI / ElevenLabs / Upstash / service-role / admin token / secret anahtarlar
    kesinlikle `NEXT_PUBLIC_` ile tanimlanamaz.
  - Server acilisinda bu tip bir degisken bulunursa uygulama baslatilmaz.
- Upstash Redis (onerilen):
  - `UPSTASH_REDIS_REST_URL`
  - `UPSTASH_REDIS_REST_TOKEN`
  - `UPSTASH_REDIS_PREFIX` (opsiyonel, varsayilan: `drkynox`)
  - Redis devre disiysa server otomatik bellek (in-memory) fallback ile devam eder.
- Upstash Workflow / QStash:
  - `QSTASH_URL`
  - `QSTASH_TOKEN`
  - `QSTASH_CURRENT_SIGNING_KEY`
  - `QSTASH_NEXT_SIGNING_KEY`
  - `WORKFLOW_PUBLIC_BASE_URL` (workflow endpointinin public backend URL'i)
  - `QSTASH_DAILY_WORKFLOW_CRON` (varsayilan: `0 0 * * *`)
  - `QSTASH_DAILY_WORKFLOW_SCHEDULE_ID` (varsayilan: `daily-challenge-refresh-v1`)
  - `QSTASH_DAILY_SCHEDULE_AUTO_SETUP` (`true` ise server acilisinda schedule otomatik olusturulur/guncellenir)
- Rate-limit detay header'lari varsayilan olarak kapali:
  - `EXPOSE_RATE_LIMIT_HEADERS=false`
- ElevenLabs session auth sertlestirmesi:
  - `POST /api/elevenlabs/session-auth` yanitinda her oturum icin yeni imzali `sessionWindowToken` doner.
  - Token claim'leri: `uid` (kullanici), `iat`, `exp`, `win`, `jti`.
  - Yanit alanlari: `sessionWindowToken`, `sessionWindowExpiresAt`, `sessionActiveWindowEndsAt`.
  - Varsayilan sureler:
    - toplam gecerlilik (`exp`): `ELEVENLABS_SESSION_TOKEN_TTL_SEC=3600` (1 saat)
    - aktif oturum penceresi (`win`): `ELEVENLABS_SESSION_WINDOW_SEC=600` (10 dakika)
- Session auth rate-limit'i IP yerine kullanici ID uzerinden uygulanir.
- Tek aktif oturum kurali:
  - `ELEVENLABS_SINGLE_ACTIVE_SESSION_ENABLED=true` iken kullanici basina ayni anda yalniz 1 aktif ElevenLabs oturumu acilabilir.
  - Oturum kapanisinda `POST /api/elevenlabs/session-end` cagrilir ve lock temizlenir.
- Gecici cache:
  - gunluk challenge cache + warmup lock
  - skor cache
  - Redis varsa paylasimli cache, yoksa process ici fallback
- Oturum maliyet limitleri:
  - Web + iOS istemcide oturum basi mesaj/karakter butcesi uygulanir (limit dolunca vaka otomatik kapanir).
  - Text agent backend limiti:
    - `TEXT_SESSION_MAX_MESSAGES`
    - `TEXT_SESSION_MAX_USER_MESSAGES`
    - `TEXT_SESSION_MAX_USER_CHARS`
- Skorlama transcript maliyet limitleri (OpenAI):
  - `SCORE_TRANSCRIPT_MAX_MESSAGES`
  - `SCORE_TRANSCRIPT_MAX_USER_MESSAGES`
  - `SCORE_TRANSCRIPT_MAX_CHARS_PER_MESSAGE`
  - `SCORE_TRANSCRIPT_MAX_TOTAL_CHARS`

## Upstash Workflow (Daily Challenge)

Express backend'e Workflow endpointi eklendi:

- `POST /api/workflow/daily-challenge` (QStash imzasi ile calisir)

Bu endpoint:
1. Gunluk vakayi force-refresh ile uretir/gunceller
2. Sonraki gunun vakasi icin warmup adimini tetikler

Admin endpointleri:

- `POST /api/admin/workflow/daily/trigger`
  - Header: `x-admin-token: <AI_ADMIN_TOKEN>`
  - Gunluk workflow'u manuel tetikler.

- `POST /api/admin/workflow/daily/schedule/setup`
  - Header: `x-admin-token: <AI_ADMIN_TOKEN>`
  - Body opsiyonel: `{ "cron": "0 0 * * *", "scheduleId": "daily-challenge-refresh-v1" }`
  - QStash schedule olusturur/gunceller.

Ornek:

```bash
curl -X POST https://<backend-domain>/api/admin/workflow/daily/schedule/setup \
  -H "Content-Type: application/json" \
  -H "x-admin-token: <AI_ADMIN_TOKEN>" \
  -d '{"cron":"0 0 * * *"}'
```

## Icerik Raporlama

- Kullanici profil ekranindan sorunlu case/konusma raporu gonderebilir.
- Backend endpoint: `POST /api/reports/create`
- Gonderilen raporlar `content_reports` tablosuna kaydedilir.
- Kullanici isterse belli bir case secerek, isterse case secmeden rapor olusturabilir.

## Kullanıcı Feedback

- Kullanici profil ekranindan konu secerek feedback mesaji gonderebilir.
- Backend endpoint: `POST /api/feedback/create`
- Gonderilen feedback kayitlari `user_feedback` tablosuna yazilir.

## ElevenLabs Tarafinda API Kullanmadan Yapman Gerekenler

Bu ornek, ElevenLabs REST API cagrisi yapmaz. O nedenle:

1. ElevenLabs dashboard'da bir Agent olustur.
2. Agent'i **public** erisime acik tut (sunucudan signed URL uretmiyoruz).
3. Agent ayarlarinda client event/mesaj yayinini ac (user transcript ve agent response eventleri).
4. `voice` mode'da tarayicida mikrofon izni ver.
5. `text` mode'da "Text Mesaji" alanindan mesaj gonder.

Not:
- Agent private olursa, istemci tarafinda dogrudan baglanmak icin token gerekir. Bu da ElevenLabs API gerektirir.
- "ElevenLabs API yok" kosulunda en pratik yol public agent + SDK event toplama akisidir.

## API Endpoint

### `POST /api/score`

Body:

```json
{
  "mode": "voice",
  "conversation": [
    { "source": "user", "message": "Merhaba" },
    { "source": "ai", "message": "Merhaba, size nasil yardimci olabilirim?" }
  ]
}
```

Donen alanlar:
- `overall_score`
- `label`
- `strengths`
- `improvements`
- `dimensions`
- `brief_summary`
- `missed_opportunities`
- `next_practice_suggestions`
