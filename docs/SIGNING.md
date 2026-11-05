# Подпись и нотаризация Sozvon

Без подписи Developer ID macOS при первом запуске пишет «не удаётся проверить разработчика»
(обход: правый клик → «Открыть»), а при каждом обновлении сбрасывает разрешения на микрофон
и запись экрана. С подписью и нотаризацией DMG открывается двойным кликом, разрешения
переживают обновления.

## 0. Что нужно

- Платное членство в Apple Developer Program ($99 в год) у команды, от имени которой подписываем.
- Роль **Account Holder** в этой команде. Сертификат Developer ID может создать только владелец
  аккаунта (или Admin, которому он выдал доступ к сертификатам). Если в списке типов нет
  «Developer ID Application», попроси владельца.
- Mac с Xcode (или хотя бы Command Line Tools) и связкой ключей.

## 1. Сертификат «Developer ID Application»

**Через Xcode (проще):**
1. Xcode → Settings → Accounts → «+» → Apple ID, войти.
2. Выбрать команду → **Manage Certificates…** → «+» → **Developer ID Application**.
3. Сертификат с закрытым ключом сам ляжет в связку ключей «Вход».

**Через сайт:**
1. «Связка ключей» → меню «Связка ключей» → «Ассистент сертификации» → «Запросить сертификат
   у бюро сертификации…». Почта, имя, «Сохранён на диске» → получится файл `.certSigningRequest`.
2. https://developer.apple.com/account/resources/certificates → «+» → **Developer ID Application**
   (профиль G2 Sub-CA) → загрузить файл запроса → скачать `.cer` → двойной клик, он встанет в связку.

**Проверка:**
```bash
security find-identity -v -p codesigning
# должно быть: "Developer ID Application: <Команда> (<TEAMID>)"
```

## 2. Ключ для нотаризации (App Store Connect API)

1. https://appstoreconnect.apple.com → Users and Access → Integrations → **App Store Connect API**
   → Team Keys → «+» (Generate API Key), роль **Developer**.
2. Скачать `AuthKey_XXXXXXXXXX.p8`. Скачать можно **только один раз**, сохрани надёжно.
3. Записать **Key ID** (в строке ключа) и **Issuer ID** (над таблицей).

(Вместо ключа можно пароль приложения: appleid.apple.com → «Пароли приложений», тогда в
`notarytool store-credentials` указываются `--apple-id`, `--team-id`, `--password`.)

## 3. Подписанная сборка на своём Mac

```bash
# один раз: сохранить ключ нотаризации в связку под именем sozvon
xcrun notarytool store-credentials sozvon \
  --key ~/Downloads/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# сборка: build.sh сам найдёт Developer ID в связке, подпишет, нотаризует и «пришьёт» тикет
NOTARY_PROFILE=sozvon ./build.sh dmg

# проверка
spctl -a -vvv -t install build/Sozvon.dmg      # должно быть: accepted, source=Notarized Developer ID
```

## 4. Подписанные релизы на GitHub

Секреты репозитория: Settings → Secrets and variables → Actions → New repository secret.

1. Экспортировать сертификат: «Связка ключей» → «Мои сертификаты» → правый клик по
   «Developer ID Application: …» → «Экспортировать» → формат `.p12`, задать пароль.
2. Положить секреты (через `gh` или вручную в веб-интерфейсе):
```bash
gh secret set DEVELOPER_ID_P12          --body "$(base64 -i ~/Desktop/DeveloperID.p12)"
gh secret set DEVELOPER_ID_P12_PASSWORD --body "пароль-от-p12"
gh secret set NOTARY_KEY_P8             --body "$(base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8)"
gh secret set NOTARY_KEY_ID             --body "XXXXXXXXXX"
gh secret set NOTARY_ISSUER_ID          --body "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```
3. Выпуск версии:
```bash
git tag v0.1.1 && git push origin v0.1.1
```
GitHub Actions (`.github/workflows/release.yml`) прогонит тесты, подпишет, нотаризует и выложит
`Sozvon-0.1.1.dmg` в Releases. Без секретов релиз тоже соберётся, но без подписи и с пометкой
pre-release.

## 5. Важно

- `.p12` и `.p8` никогда не коммитить (они в `.gitignore`). Удали локальные копии после загрузки
  в секреты, оригинал сертификата останется в связке.
- Bundle id `io.github.able1991.sozvon` не меняем: от него зависят разрешения пользователей.
- При переходе с локальной подписи на Developer ID разрешения у тех, кто ставил неподписанную
  версию, один раз слетят. Дальше обновления их не трогают.
- Сертификат Developer ID действует 5 лет. Уже подписанные и нотаризованные версии продолжают
  работать и после его истечения.
