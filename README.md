# Codex OmniRoute

Codex OmniRoute запускает официальный Codex Desktop через локальный шлюз
OmniRoute. Обычный Codex остаётся обычным, а окно **Codex OmniRoute**
направляет основные reasoning-запросы через локальный мост.

Главная идея простая: оба режима используют один официальный дом Codex:

```text
C:\Users\<you>\.codex
```

Значит, авторизация, история чатов, MCP-серверы, плагины, коннекторы,
кэш моделей, tool discovery и сессии остаются общими с официальным Codex.
Отдельный `.codex-omniroute-home` больше не используется как активный
`CODEX_HOME`.

## Быстрая установка

Этот путь рассчитан на обычную Windows-машину, где уже установлен
официальный Codex Desktop.

1. Установи официальный **OpenAI Codex** из Microsoft Store.
2. Открой официальный Codex хотя бы один раз и войди в аккаунт.
3. Скачай этот репозиторий с GitHub:
   - через **Code** -> **Download ZIP**;
   - или через `git clone`.
4. Распакуй проект в понятную папку, например:

   ```text
   C:\AI\Bots\Codex-Omniroute
   ```

5. Запусти `Setup.exe` из папки проекта.

   В PowerShell это выглядит так:

   ```powershell
   .\Setup.exe
   ```

6. Если setup попросит данные OmniRoute, введи:
   - base URL, например `https://your-omniroute.example/v1`;
   - API key для OmniRoute;
   - optional image API key, если изображения идут через отдельный ключ.

7. После завершения запускай **Codex OmniRoute** с рабочего стола или из
   меню **Start**.

Официальный Codex при этом остаётся доступен отдельно: через обычный ярлык
Codex или через ярлык **Codex Official**, который создаёт setup.

> **Note:** `Setup.exe` не подписан сертификатом издателя. Если Windows
> SmartScreen покажет предупреждение, открой **More info** и выбери
> **Run anyway**, если ты доверяешь локальной копии репозитория.

## Что делает `Setup.exe`

`Setup.exe` нужен, чтобы пользователь не собирал окружение руками. Он
использует встроенный Windows PowerShell и выполняет установку в user-space,
без глобального патчинга Codex.

Во время установки setup:

- проверяет, что официальный Codex Desktop установлен;
- ставит локальный Node.js и локальный .NET SDK в
  `%LOCALAPPDATA%\CodexOmniRoute\deps`, если они нужны;
- создаёт или обновляет `omniroute-provider.json`;
- готовит отдельную копию Electron-приложения в
  `%LOCALAPPDATA%\CodexOmniRoute\WindowsApp`;
- хранит отдельное состояние окна OmniRoute в
  `%LOCALAPPDATA%\CodexOmniRoute\ElectronUserData`;
- собирает маленький `app-server` wrapper для OmniRoute-окна;
- создаёт ярлыки **Codex OmniRoute** и **Codex Official**;
- запускает verifier, который проверяет shared-home gateway.

Setup не пишет глобальный `model_provider = "omniroute"` в общий
`config.toml` и не переключает официальный Codex на OmniRoute.

## Что должно получиться

После установки у тебя есть два режима:

- **Codex Official**: обычный официальный Codex без OmniRoute overrides.
- **Codex OmniRoute**: отдельное окно Codex, где основные reasoning-запросы
  идут через локальный OmniRoute bridge.

Оба режима читают один и тот же Codex home:

```text
%USERPROFILE%\.codex
```

Поэтому в OmniRoute-окне должны быть видны те же MCP-серверы, плагины,
коннекторы, auth state, история и кэш, что и в официальном Codex.

## Проверка установки

Обычный пользователь может просто запустить **Codex OmniRoute** и отправить
сообщение в окно. Если окно отвечает, базовый сценарий работает.

Для технической проверки запусти:

```powershell
.\verify-codex-omniroute.ps1
```

Для более глубокой проверки всех MCP из общего Codex config:

```powershell
.\verify-codex-omniroute.ps1 -ProbeAllMcp
```

Когда OmniRoute запущен, диагностика моста доступна здесь:

```text
http://127.0.0.1:20333/healthz
```

В поле `main_reasoning_hits` видно, приходили ли реальные reasoning-запросы
из Codex Desktop в OmniRoute bridge.

## Обновление

Чтобы обновить проект, замени файлы репозитория новой версией и снова запусти:

```powershell
.\Setup.exe
```

Setup можно запускать повторно. Он обновит gateway, wrapper и ярлыки без
переноса истории, auth или MCP-конфига в отдельный профиль.

## Если что-то пошло не так

Начни с мягкого восстановления:

```powershell
.\Start-Codex-OmniRoute.ps1 -Restore
```

Эта команда останавливает управляемый bridge и окно OmniRoute. Общий
`%USERPROFILE%\.codex` она не удаляет.

Типовые проблемы:

- **Setup пишет, что официальный Codex не установлен.** Установи Codex из
  Microsoft Store, открой его один раз, войди в аккаунт, затем снова запусти
  `Setup.exe`.
- **Setup просит OmniRoute base URL или API key.** Введи значения вручную
  или заранее создай `omniroute-provider.json` рядом с `Setup.exe`.
- **Один MCP показывает `auth_required`.** Это значит, что MCP есть в общем
  Codex config, но ему не хватает токена или OAuth-доступа. Настрой ключи в
  обычном Codex home, потому что OmniRoute использует тот же shared home.
- **OmniRoute не отвечает.** Запусти `.\verify-codex-omniroute.ps1` и посмотри
  `bridge.log`, если файл появился после запуска launcher.

## Настройка провайдера вручную

Setup обычно сам создаёт `omniroute-provider.json`. Если хочешь сделать это
руками, скопируй пример:

```powershell
Copy-Item .\omniroute-provider.example.json .\omniroute-provider.json
```

Затем заполни:

```json
{
  "base_url": "https://your-omniroute.example/v1",
  "api_key": "YOUR_OMNIROUTE_KEY",
  "model_prefix": "cx/",
  "default_model": "gpt-5.5",
  "image_api_key": "",
  "image_model": "chatgpt-web/gpt-5.3-instant",
  "model_aliases": {
    "gpt-5.5": "gpt-5.5-xhigh"
  }
}
```

Не коммить `omniroute-provider.json`: в нём лежат локальные ключи.

## Ручной запуск

Обычно достаточно ярлыка **Codex OmniRoute**. Эти команды нужны для
диагностики и разработки.

Установить или проверить локальные зависимости:

```powershell
.\tools\Install-CodexOmniRouteDependencies.ps1
```

Запустить OmniRoute-окно:

```powershell
.\Start-Codex-OmniRoute.ps1
```

Запустить только bridge без окна Codex:

```powershell
.\Start-Codex-OmniRoute.ps1 -NoCodex
```

Запустить официальный Codex без OmniRoute:

```powershell
.\Start-Codex-Official.ps1
```

Пересобрать `Setup.exe` из исходников:

```powershell
.\tools\Build-SetupExe.ps1
```

## Маршрутизация

OmniRoute перехватывает только то, что должно идти через OmniRoute. Остальное
остаётся на официальном backend Codex.

| Запрос | Куда идёт |
| --- | --- |
| `/v1/responses` | OmniRoute bridge |
| `/v1/chat/completions` | OmniRoute bridge |
| `/v1/images/generations` | OmniRoute image lane |
| `/v1/images/edits` | OmniRoute image lane |
| `/v1/responses/compact` | Official Codex/OpenAI backend |
| `/v1/audio/transcriptions`, `/transcribe` | Official Codex/OpenAI backend |
| `/v1/models` | Shared `%USERPROFILE%\.codex\models_cache.json` |

Компактинг и диктовка остаются официальными. Основное reasoning и image lane
идут через OmniRoute.

## Tool search и apply patch

Codex-native tools должны продолжать работать в OmniRoute-окне.

Для `tool_search` bridge добавляет function shim `omniroute_tool_search`.
Если upstream-модель вызывает этот shim, bridge переписывает ответ обратно в
native `tool_search_call`, который выполняет Codex Desktop.

Для `apply_patch` bridge сохраняет native/freeform путь. Если upstream
возвращает function-style patch call, bridge переписывает его обратно в
Codex-native custom tool call. Локальный fallback также умеет применять
маленькие патчи к временным файлам, включая пути с Unicode.

## Изображения и ограничение 10MB

Image lane настроен по SuperCodex-style схеме: изображения идут через
OmniRoute, а compact и dictation остаются official.

Если у image gateway отдельный ключ, укажи его при setup или через
`omniroute-provider.json`:

```json
{
  "image_api_key": "YOUR_IMAGE_KEY",
  "image_model": "chatgpt-web/gpt-5.3-instant"
}
```

Некоторые OmniRoute-compatible upstreams отклоняют request body больше 10MB.
Bridge держит свежие inline images в запросе, старые inline images складывает
в локальный media cache и заменяет их текстовыми placeholders перед отправкой.

Основные лимиты:

```text
CODEX_OMNI_OMNIROUTE_MAX_BODY_BYTES=10485760
CODEX_OMNI_INLINE_IMAGE_HISTORY_BUDGET_BYTES=6291456
CODEX_OMNI_MEDIA_CACHE_MAX_BYTES=536870912
```

## Архитектура коротко

На Windows launcher использует duplicate-app gateway:

1. Копирует официальный Store app в
   `%LOCALAPPDATA%\CodexOmniRoute\WindowsApp`.
2. Оставляет официальный `CODEX_HOME` равным `%USERPROFILE%\.codex`.
3. Выносит только Electron UI state OmniRoute-окна в
   `%LOCALAPPDATA%\CodexOmniRoute\ElectronUserData`.
4. Сохраняет официальный CLI как `resources\codex-official.exe`.
5. Заменяет только `resources\codex.exe` в duplicate app на wrapper.
6. Wrapper запускает `codex-official.exe app-server` с process-level
   `-c` overrides для OmniRoute.

Главные overrides:

```powershell
-c 'model_provider="omniroute"'
-c 'model="gpt-5.5"'
-c 'model_reasoning_effort="xhigh"'
-c 'features.tool_search=true'
-c 'features.apply_patch_freeform=true'
-c 'model_providers.omniroute.base_url="http://127.0.0.1:20333/v1"'
-c 'model_providers.omniroute.wire_api="responses"'
-c 'model_providers.omniroute.env_key="OMNIROUTE_API_KEY"'
-c 'model_providers.omniroute.requires_openai_auth=true'
-c 'model_providers.omniroute.supports_websockets=false'
```

Эти overrides живут только в процессе **Codex OmniRoute**. Они не становятся
глобальной настройкой официального Codex.

## Legacy заметка

Старые версии могли создавать `.codex-omniroute-home`. Новая архитектура не
использует эту папку как активный `CODEX_HOME`, не копирует туда auth/history
и не импортирует туда MCP config. Если такая папка осталась после старой
версии, она считается legacy artifact.
