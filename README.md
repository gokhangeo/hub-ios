# Bulutsuz Transfer iOS

[Bulutsuz Transfer (HUB)](https://gokhangeo.github.io/hub/) için yerel iOS uygulaması: paylaş menüsünden Android ve Windows'a bulutsuz (WebRTC, PeerJS uyumlu) gönderim, uygulamada alma.

- SwiftUI + Share Extension, `stasel/WebRTC`
- HUB protokol v2 ile birebir uyumlu: 6 haneli kod (gönderen bir kez Kabul eder), gizli anahtarlı QR (onaysız), 64 KB parçalar, SHA-256 doğrulama
- Mac gerekmez: GitHub Actions her push'ta imzasız IPA üretir (Releases). iloader / SideStore ile kendi Apple ID'nizle imzalayıp yükleyin.

Kısıt: iOS arka planda alma yapmaya izin vermez; aktarım sırasında uygulama (veya paylaş penceresi) açık kalmalı.
