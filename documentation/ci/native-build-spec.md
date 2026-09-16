# Спецификация: удалённая сборка нативных библиотек SkiaSharp

Как форк `SoftSmile-Inc/SkiaSharp` производит артефакты для Unity-проекта `vision` и как они туда
попадают. Документ описывает, что должно получиться; выбор между вариантами зафиксирован в
[ADR](../adr/). Терминология — в [CONTEXT.md](../../CONTEXT.md).

Статус: согласовано, не реализовано.

---

## 1. Задача

Сегодня библиотеки собираются на машине разработчика и копируются в `vision` руками. Какая
сборка породила лежащие там байты — не записано нигде; совпадает ли их версия с той, что бэкенд
тянет из NuGet, — тоже. Цель CI: сделать сборку воспроизводимой по тегу, а соответствие версий —
проверяемым автоматически.

Из форка собирается не всё. Stock-пакеты с nuget.org используются везде, где правка форка
соответствующий таргет не затрагивает.

---

## 2. Матрица артефактов

| Слот в `Assets/ExternalPlugins/` | Источник | Почему |
|---|---|---|
| `WebGL/libSkiaSharp.a` | форк-сборка | переименование символов freetype2/libjpeg-turbo/libpng |
| `WebGL/libHarfBuzzSharp.a` | форк-сборка | сокрытие, переименование и обратный алиасинг символов harfbuzz |
| `WebGL/SkiaSharp.dll` | форк-сборка | `__Internal` в P/Invoke |
| `WebGL/HarfBuzzSharp.dll` | форк-сборка | `__Internal` в P/Invoke |
| `x86_64/libHarfBuzzSharp.so` | форк-сборка | `-Wl,-Bsymbolic-functions` против интерпозиции символов |
| `x86_64/libSkiaSharp.so` | stock | `SkiaSharp.NativeAssets.Linux.NoDependencies`, `runtimes/linux-x64/native/` |
| `x86_64/libSkiaSharp.dll` | stock | `SkiaSharp.NativeAssets.Win32`, `runtimes/win-x64/native/` |
| `x86_64/libHarfBuzzSharp.dll` | stock | `HarfBuzzSharp.NativeAssets.Win32`, `runtimes/win-x64/native/` |
| `MacOS/libSkiaSharp.dylib` | stock | `SkiaSharp.NativeAssets.macOS`, `runtimes/osx/native/` (universal) |
| `MacOS/libHarfBuzzSharp.dylib` | stock | `HarfBuzzSharp.NativeAssets.macOS`, `runtimes/osx/native/` (universal) |
| `SkiaSharp.dll`, `SkiaSharp.HarfBuzz.dll`, `HarfBuzzSharp.dll` (корень) | stock | обычные managed-сборки для всех платформ кроме WebGL |

Не производится и не поддерживается: `linux-arm64`, `win-x86`, `win-arm64`, а также
`__Internal`-варианты `SkiaSharp.Skottie`, `SkiaSharp.SceneGraph`, `SkiaSharp.Resources` — их нет
в графе зависимостей Unity-приложения.

`.meta`-файлы слотов закоммичены в `vision` и содержат настройки платформ. CI их **не трогает**:
обновление бандла заменяет байты, GUID и настройки импорта сохраняются.

---

## 3. Джобы сборки

Все четыре независимы и выполняются параллельно. Конфигурация везде Release.

### 3.1. wasm

```bash
bash scripts/Docker/wasm/build-local.sh 3.1.39 \
  --wasmRenameThirdPartySymbols=true \
  --emscriptenFeatures=_wasmeh,st,simd
```

Команда фиксирована и изменению не подлежит. Она сама собирает образ `skiasharp-wasm:3.1.39`,
запускает в нём `dotnet cake --target=externals-wasm` и производит оба архива.

Результат ложится во внутренний layout:

```
output/native/wasm/libSkiaSharp.a/3.1.39/st,simd/libSkiaSharp.a
output/native/wasm/libHarfBuzzSharp.a/3.1.39/st,simd/libHarfBuzzSharp.a
```

Вложенность `<версия>/<модификаторы>/` — следствие того, что элементы набора фич, начинающиеся с
`_`, из пути выбрасываются, а остальные джойнятся через запятую. Это ожидаемое поведение,
менять его нельзя: тот же layout является входом для nuspec и `IncludeNativeAssets.*.targets`.

Набор фич `_wasmeh,st,simd` выведен из `ProjectSettings/ProjectSettings.asset` Unity-проекта:
`webGLThreadsSupport: 0` даёт `st`, `webWasm2023: 1` включает native WebAssembly exceptions и SIMD,
что соответствует `_wasmeh` и `simd`.

Образ `skiasharp-wasm:3.1.39` остаётся в локальном docker после сборки и используется джобой
проверок (§5.1).

### 3.2. linux

```bash
cd scripts/Docker/debian/amd64 && docker build --tag skiasharp-linux-x64 .
cd - && docker run --rm --volume "$(pwd)":/work skiasharp-linux-x64 /bin/bash -c \
  "dotnet tool restore && dotnet cake native/linux/build.cake --target=libHarfBuzzSharp --buildarch=x64"
```

Собирается только таргет `libHarfBuzzSharp` — это один амальгамированный `.cc`, минуты, а не
полная сборка Skia. Результат: `output/native/linux/x64/libHarfBuzzSharp.so` и версионированный
`libHarfBuzzSharp.so.<soname>`.

### 3.3. managed `__Internal`

```bash
dotnet build binding/SkiaSharp/SkiaSharp.csproj -f netstandard2.1 -c Release \
  -p:SkiaSharpUnityWebGLInternal=true -o artifacts/unity-webgl
dotnet build binding/HarfBuzzSharp/HarfBuzzSharp.csproj -f netstandard2.1 -c Release \
  -p:SkiaSharpUnityWebGLInternal=true -o artifacts/unity-webgl
```

Проверено: обе сборки проходят в чистом `mcr.microsoft.com/dotnet/sdk:8.0` без единого файла в
`output/native/`, примерно за две секунды каждая. TFM именно `netstandard2.1`; `net8.0` не
подходит.

Свойство `SkiaSharpUnityWebGLInternal` передаётся именно как свойство, а не через
`-p:DefineConstants=...` — глобальное присвоение `DefineConstants` ломает собственные
`<DefineConstants>` проекта, включая тот, что выставляет `USE_LIBRARY_IMPORT`.

### 3.4. stock-нативы

Скачать с nuget.org и распаковать пять пакетов, взяв по одному файлу из каждого:

| Пакет | Версия | Файл |
|---|---|---|
| `SkiaSharp.NativeAssets.Win32` | 3.119.2 | `runtimes/win-x64/native/libSkiaSharp.dll` |
| `HarfBuzzSharp.NativeAssets.Win32` | 8.3.1.3 | `runtimes/win-x64/native/libHarfBuzzSharp.dll` |
| `SkiaSharp.NativeAssets.macOS` | 3.119.2 | `runtimes/osx/native/libSkiaSharp.dylib` |
| `HarfBuzzSharp.NativeAssets.macOS` | 8.3.1.3 | `runtimes/osx/native/libHarfBuzzSharp.dylib` |
| `SkiaSharp.NativeAssets.Linux.NoDependencies` | 3.119.2 | `runtimes/linux-x64/native/libSkiaSharp.so` |

Версии не хардкодятся в workflow: они читаются из `scripts/VERSIONS.txt` собираемого ref
(строки `SkiaSharp ... nuget` и `HarfBuzzSharp ... nuget`), чтобы stock-часть бандла не могла
разойтись с той версией, из которой собрана форк-часть.

---

## 4. Версионирование и манифест

**Версия бандла** берётся из git-тега форка вида `v3.119.2-ss.N`: базовая часть совпадает с
upstream-релизом, суффикс наш. Сборка с ветки без тега даёт `3.119.2-dev.<короткий-sha>`.

**`versions.json`** кладётся в корень `Assets/ExternalPlugins/` вместе с файлами:

```json
{
  "bundle": "3.119.2-ss.1",
  "ref": "release/3.119.2-wasm-symbols-renaming",
  "commit": "3472e4041...",
  "builtAt": "2026-09-16T12:00:00Z",
  "skiaSharp": "3.119.2",
  "harfBuzzSharp": "8.3.1.3",
  "emscripten": "3.1.39",
  "unity": "6000.3.8f1",
  "emscriptenFeatures": "_wasmeh,st,simd",
  "files": [
    { "slot": "WebGL/libSkiaSharp.a", "source": "fork", "sha256": "..." },
    { "slot": "x86_64/libSkiaSharp.dll", "source": "nuget:SkiaSharp.NativeAssets.Win32/3.119.2", "sha256": "..." }
  ]
}
```

Поля `skiaSharp` и `harfBuzzSharp` — две независимые версионные оси; именно на их смешении
возникает рассинхрон, поэтому они записываются раздельно. Поле `unity` фиксирует, под какую
версию редактора собран wasm (см. §7.3).

---

## 5. Проверки

### 5.1. Блокирующие публикацию

Выполняются в джобе сборки, сразу после неё, в том же образе. Ни одна не требует Unity.

**Переименование сработало.** На `libSkiaSharp.a`:

```bash
docker run --rm --volume "$(pwd)":/work skiasharp-wasm:3.1.39 \
  emnm --defined-only --extern-only \
  output/native/wasm/libSkiaSharp.a/3.1.39/st,simd/libSkiaSharp.a
```

- нет глобальных символов, начинающихся с `FT_`, `png_`, `jpeg_` без префикса `sksharp_`;
- символы `sksharp_*` присутствуют;
- символы `sk_*` присутствуют под исходными именами — собственный C API SkiaSharp затронут быть
  не должен.

Про `Cr_z_*` (zlib) проверок нет: zlib сознательно исключён из механизма, его вендоренный
Chromium-форк уже префиксует свои символы сам.

**Алиасинг harfbuzz сработал.** На `libHarfBuzzSharp.a`: каждое имя `hb_*`, которое
P/Invoke'ит managed-биндинг (список извлекается из `binding/HarfBuzzSharp/HarfBuzzApi.cs` и
`HarfBuzzApi.generated.cs` тем же способом, что и в `GetHarfBuzzManagedApiNames`), присутствует
в архиве под **исходным** именем. Если алиасы не проставились, плеер упадёт при старте — эта
проверка стоит секунды и ловит то, на что иначе уйдёт полчаса ручной работы.

**`__Internal` попал в managed-сборки.** В `SkiaSharp.dll` и `HarfBuzzSharp.dll` присутствует
строка `__Internal` и отсутствуют `libSkiaSharp` / `libHarfBuzzSharp`. Проверка выполнена
вручную на текущем коде и работает надёжно.

### 5.2. Сторож незащищённых C++-символов

Считает в `libHarfBuzzSharp.a` глобальные символы, начинающиеся с `_Z` (mangled C++) и **не**
имеющие префикса `sksharp_`. Падает, если число выросло относительно зафиксированной базовой
линии.

Базовая линия **на момент написания не измерена** и фиксируется первым прогоном CI: её надо
записать в этот файл и в `documentation/adr/0003-*`. Не путать с числом 1027 — это другая
величина: количество имён, совпадающих одновременно в нашем архиве и в архиве Unity
`WebGLSupport_UnityPlayer.TextRenderingModule_Dynamic.a`, то есть подтверждённая поверхность
столкновения, а не общее число незащищённых символов.

Сторож ничего не чинит. Он превращает молчаливый риск в сигнал на нашей стороне при DEPS-бампе
harfbuzz, смене флагов или правке механизма. Обоснование — [ADR 0003](../adr/0003-harfbuzz-cpp-internals-residual-risk.md).

### 5.3. Приёмка

Автоматической приёмки нет. Бандл считается пригодным после того, как на нём собран Web DFA,
задеплоен на dev и проверен человеком в браузере — рендер отшейпленного текста разными шрифтами.
Это решение разработчика: ни одна автоматическая проверка его в этом не убеждает.

---

## 6. Публикация

Релизная сборка (по тегу) прикладывает бандл к GitHub Release этого тега. Бандл — один архив:
файлы, разложенные по именам слотов, плюс `versions.json`.

Дев-сборка (ветка без тега) кладёт тот же архив в артефакты прогона, ретенция 14 дней, в Release
не попадает.

Релизы хранятся бессрочно. В S3 не дублируются: бандл воспроизводим из тега, а вторая копия —
это второе место, где версия может разойтись.

---

## 7. Доставка в `vision`

### 7.1. Предварительное условие

**До первого прогона CI** отдельным MR в `vision` добавить в `.gitattributes`:

```
*.a filter=lfs diff=lfs merge=lfs -text
*.dylib filter=lfs diff=lfs merge=lfs -text
```

и перевести уже закоммиченные файлы через `git lfs migrate import --no-rewrite` (эта команда
упомянута комментарием в самом `.gitattributes`). Сейчас `libSkiaSharp.a` (15.1 МБ),
`libHarfBuzzSharp.a` (3.4 МБ) и `libSkiaSharp.dylib` (~15.8 МБ) лежат сырыми блобами. Записаны
они по одному разу, поэтому ущерба ещё нет — но каждое обновление бандла добавит в историю
`vision` ещё около 35 МБ навсегда.

### 7.2. Перенос

Ручная джоба в пайплайне `vision` с параметром «версия бандла». Она скачивает архив с GitHub
Release, раскладывает файлы по слотам, пишет `versions.json`, коммитит в новую ветку и открывает
MR.

Направление доступа выбрано осознанно: GitLab ходит на GitHub, а не наоборот. Релизы публичного
репозитория читаются анонимно, поэтому ни один секрет не пересекает границу систем и в публичном
форке не появляется токена с правом записи в основной репозиторий. Обоснование —
[ADR 0002](../adr/0002-ci-home-for-public-fork.md).

### 7.3. Проверка согласованности

Джоба в пайплайне `vision`, блокирующая MR. Сверяет `versions.json` с двумя источниками:

1. `skiaSharp` и `harfBuzzSharp` — против `PackageReference` в csproj бэкенда
   (`Backend/SoftSmile.Vision.Fonts/SoftSmile.Vision.Fonts.csproj`);
2. `unity` — против `UNITY_VERSION` в `ci/unity-mono-gitlab-ci.yml`.

Вторая проверка ловит апгрейд Unity. Версия emscripten жёстко следует из версии Unity
(6000.3.8f1 несёт 3.1.39), а лежащий в слотах `.a` — полуфабрикат, который дособирает сама Unity
своим тулчейном. Если версии разошлись, `.a` собран не тем компилятором: это проявится либо
ошибкой линковки, либо странностями в рантайме, и никто не свяжет их с апгрейдом, сделанным
тремя неделями раньше. Проверка превращает это в понятное сообщение в том самом MR, который
поднимает версию Unity.

Проверку нельзя ставить в джобу `build AWS Web DFA`: на merge request она объявлена как
`when: manual` с `allow_failure: true`, то есть гейтом быть не может.

---

## 8. Триггеры

- **`workflow_dispatch`** с обязательным параметром `ref` (ветка или тег) и необязательными
  `emscripten_version`, `emscripten_features`. Параметр `ref` обязателен потому, что новые версии
  SkiaSharp приезжают черри-пиком наших коммитов на новую release-ветку — фиксированной ветки для
  сборки не существует.
- **push тега `v*-ss.*`** — релизная сборка с публикацией.
- Push в `release/*` без тега не собирается.
- Триггера `pull_request` нет и быть не должно.

---

## 9. Раннер

Сборка идёт на **GitHub-hosted `ubuntu-latest`**. Для публичного репозитория это 4 ядра, 16 ГБ
RAM и 14 ГБ SSD; минуты бесплатны и не лимитированы, лимит джобы — 6 часов.

`build-local.sh` работает там дословно: шаги `run:` исполняются на хосте, docker установлен,
`$(pwd)` — настоящий путь хоста. Это существенно: под docker-executor с проброшенным сокетом
(конфигурация сборочного флота GitLab) `docker run -v $(pwd):/work` смонтировал бы
несуществующий путь и сборка стартовала бы в пустом каталоге.

14 ГБ недостаточно: один wasm-прогон занимает порядка 12–18 ГБ (чекаут, `externals/skia` с
зависимостями после `git-sync-deps`, `depot_tools`, образ с emsdk, `out/wasm`, `out/wasm-symgen`
и merge-директория). Поэтому джоба начинается со штатного шага освобождения диска — сноса
преустановленных Android SDK, .NET, GHC и CodeQL, что даёт дополнительно 25–45 ГБ.

Требования по изоляции публичного форка выполняются по устройству: раннер эфемерный, вне нашей
VPC, доступа к боевым сервисам не имеет. Секретов у сборки нет вообще — `GITHUB_TOKEN` нужен
только для создания релиза.

**Порог переезда на self-hosted.** Первый прогон измеряет время и пиковый размер на диске; обе
величины записываются сюда. Переезжаем, если выполнено любое из:

- не помещаемся в диск даже после шага очистки;
- холодная сборка стабильно дольше 90 минут.

Переезд — это смена `runs-on:` плюс провижининг EC2 (c7a.4xlarge, 200+ ГБ gp3, executor shell,
агент `--ephemeral`, отдельная security group с исходящим 443 через NAT). Остальная часть
спецификации от этого не зависит.

---

## 10. Открытые вопросы

1. **Выполняется ли генерация PDF внутри WebGL-плеера.** `UnityApp.csproj` ссылается на
   `TreatmentPlanReportPdfGenerator` (→ QuestPDF `[2022.12.0]`), и на Unity-стороне есть
   `Assets/Tzergity/Modules/PostProcessing/Services/TreatmentPlanPdfGenerator.cs`,
   зарегистрированный в DI. QuestPDF этой версии компилировался против SkiaSharp 2.88, а NuGet
   унифицирует SkiaSharp до 3.119.2. Разработчик сообщает, что проблем нет; ручная проверка
   рендера текста этот путь не затрагивает. Если PDF генерируется в плеере — нужен отдельный
   пункт приёмки.
2. **Базовая линия сторожа** (§5.2) — фиксируется первым прогоном.
3. **Время и пиковый размер холодной wasm-сборки** (§9) — измеряются первым прогоном.
4. **Владельцы.** Кто может менять Settings → Actions в организации `SoftSmile-Inc` (в частности
   включить «Require approval for all external contributors») и кто апрувит изменения
   `.gitlab-ci.yml` в `vision` — не установлено.
