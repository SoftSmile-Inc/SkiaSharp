# Вопросы по удалённой сборке нативных библиотек SkiaSharp

Мы настраиваем CI для форка `SoftSmile-Inc/SkiaSharp`, чтобы сборка wasm/нативных библиотек
перестала быть ручной операцией на чьей-то машине. Цель текущего этапа — согласованная
спецификация, а не код.

Ниже только те вопросы, ответы на которые **не выводятся из репозитория**. Всё, что можно было
прочитать в коде, уже прочитано — см. раздел «Что уже установлено», чтобы не тратить время на
подтверждение известного.

---

## Что уже установлено (проверено, подтверждать не нужно)

**Версия emscripten.** Unity 6000.3.8f1 несёт `3.1.39-git` (проверено в образе
`registry.gitlab.com/softsmile_group/vision/editor:ubuntu-6000.3.8f1-webgl-pwsh-3.2.1`, файл
`PlaybackEngines/WebGLSupport/BuildTools/Emscripten/emscripten/emscripten-version.txt`).
Тулчейн — форк Unity: `clang version 17.0.0 (Unity-Technologies/llvm-project 7c3f21cd)`.

**Набор фич подтверждается настройками проекта** (`vision/ProjectSettings/ProjectSettings.asset`):
`webGLThreadsSupport: 0` → однопоточно (`st`); `webWasm2023: 1` → по документации Unity включает
native WebAssembly exceptions и SIMD (`_wasmeh` + `simd`); `webGLLinkerTarget: 1` → wasm.
То есть `--emscriptenFeatures=_wasmeh,st,simd` — верный набор.

**Путь вывода.** В `native/wasm/build.cake` элементы набора фич, начинающиеся с `_`, из пути
выбрасываются, остальные джойнятся через запятую. Для `_wasmeh,st,simd` результат ложится в
`output/native/wasm/libSkiaSharp.a/3.1.39/st,simd/`. Это ожидаемое поведение, а не сбой.

**Версии в Unity-проекте.** `Backend/SoftSmile.Vision.UnityApp/obj/project.assets.json` резолвит
`SkiaSharp/2.88.8`, `SkiaSharp.HarfBuzz/2.88.3`, `HarfBuzzSharp/7.3.0.2`, `SkiaSharp.Svg/1.60.0`,
`SkiaSharp.NativeAssets.{Win32,macOS,Linux.NoDependencies}/2.88.8`; QuestPDF закреплён точно как
`[2022.12.0]`. Форк при этом отведён от `release/3.119.2`.

**Куда попадает натив.** Не в `Assets/Plugins`. Четыре файла (`libSkiaSharp.{dll,dylib}`,
`libHarfBuzzSharp.{dll,dylib}`) закоммичены в `Backend/SoftSmile.Vision.UnityApp/` и объявлены
как `<Content CopyToOutputDirectory="PreserveNewest">`, а `<OutDir>` этого csproj —
`../../Assets/ExternalDependencies`. Сам каталог `Assets/ExternalDependencies` и его `.meta`
в `.gitignore`.

**Бэкпорт на `v2.88.8` структурно выполним.** Проверено, что на теге `v2.88.8` уже есть:
механизм `--emscriptenFeatures` с `_wasmeh`/`simd`/`mt` и та же логика построения пути;
`visibility_hidden=false` в wasm-таргете `libHarfBuzzSharp`; идентичная строка `extra_ldflags`
в `native/linux/build.cake`; паттерн `#if __IOS__ || __TVOS__` для константы модуля.
Ключевое: `BUILD.gn` обеих ревизий skia (m88 и m119) собирает таргет `HarfBuzzSharp` из
единственного источника `harfbuzz-subset.cc` — то есть требование «одна единица трансляции»,
на котором держится `__attribute__((alias(...)))`, выполняется и там.
Расхождения при переносе: файлы биндинга лежат по другим путям
(`binding/Binding/SkiaApi.cs`, `binding/HarfBuzzSharp.Shared/HarfBuzzApi{,.generated}.cs`), а
`GetHarfBuzzManagedApiNames` в `native/wasm/build.cake` обращается к путям 3.x жёстко;
harfbuzz там 7.3.0 против 8.3.1.

**Managed-сборки с `__Internal` собираются тривиально.** Проверено запуском в чистом
`mcr.microsoft.com/dotnet/sdk:8.0` без единого файла в `output/native/`:

```
dotnet build binding/SkiaSharp/SkiaSharp.csproj -f netstandard2.1 -c Release \
  -p:SkiaSharpUnityWebGLInternal=true -o <out>
dotnet build binding/HarfBuzzSharp/HarfBuzzSharp.csproj -f netstandard2.1 -c Release \
  -p:SkiaSharpUnityWebGLInternal=true -o <out>
```

Обе сборки проходят за ~1–2 секунды. В полученных `SkiaSharp.dll` / `HarfBuzzSharp.dll` строка
`__Internal` присутствует, а `libSkiaSharp` / `libHarfBuzzSharp` отсутствуют; в контрольной
сборке без флага — наоборот. Скиа при этом не нужна вообще.

---

## 1. Линия версий — самый важный блок

Unity-проект и бэкенд сидят на SkiaSharp **2.88.8**, а вся работа по переименованию символов,
`__Internal` и `-Bsymbolic-functions` сделана на **3.119.2**. Managed `SkiaSharp.dll` в плеере
ровно один, поэтому «wasm из 3.119.2 рядом с десктопным нативом 2.88.8» невозможно: либо всё
переезжает на 3.x, либо работа бэкпортится на 2.88.x.

**1.1.** Планируется ли апгрейд QuestPDF (сейчас `[2022.12.0]`) и бэкенда на SkiaSharp 3.x?
Если да — в каком горизонте? От этого зависит, делаем ли мы бэкпорт как временную меру или
вообще не делаем.

**1.2.** Отдельно про `SkiaSharp.Svg 1.60.0`: пакет заброшен, версии под 3.x у него нет.
Известно ли, что с ним делать при апгрейде — заменять, выпиливать, форкать?

**1.3.** Собиралась ли эта работа хоть раз на линии 2.88.x? Если пробовали — на что упёрлись?

**1.4.** Когда проверяли `libSkiaSharp.a` в Unity — managed `SkiaSharp.dll` какой версии лежал
рядом? 2.88.8 из `ExternalDependencies` или вручную подложенный 3.119.2?

---

## 2. Что именно нужно собирать из форка

Наша текущая матрица. Прошу подтвердить или поправить:

| Слот | Источник | Почему |
|---|---|---|
| `wasm/libSkiaSharp.a` | форк | переименование freetype2/libjpeg-turbo/libpng |
| `wasm/libHarfBuzzSharp.a` | форк | hide + rename + alias |
| `linux-x64/libHarfBuzzSharp.so` | форк | `-Wl,-Bsymbolic-functions` |
| `SkiaSharp.dll` (netstandard2.1, `__Internal`) | форк | P/Invoke в Unity WebGL |
| `HarfBuzzSharp.dll` (netstandard2.1, `__Internal`) | форк | то же |
| `win-x64/libSkiaSharp.dll`, `libHarfBuzzSharp.dll` | stock с nuget.org | как сейчас |
| `osx/libSkiaSharp.dylib`, `libHarfBuzzSharp.dylib` (universal) | stock с nuget.org | как сейчас |
| `linux-x64/libSkiaSharp.so` | **?** | см. 2.1 |

**2.1.** `libSkiaSharp.so` для Linux — можно брать stock с nuget.org, или его тоже надо собирать
из форка? Правка `-Bsymbolic-functions` затронула только таргет `libHarfBuzzSharp`, поэтому по
коду выходит, что `libSkiaSharp.so` не отличается от официального. Есть причина считать иначе?

**2.2.** `libHarfBuzzSharp.so` нужен для Unity Standalone Linux Player, для Unity Editor
в сборочном Linux-образе, или для обоих? Это определяет, попадает ли он в бандл для
Unity-проекта или нужен только на сборочной машине.

**2.3.** Нужны ли `__Internal`-варианты `SkiaSharp.Skottie`, `SkiaSharp.SceneGraph`,
`SkiaSharp.Resources`? В графе зависимостей Unity-приложения их сейчас нет, но в документации
отмечено, что тот же однострочный фикс к ним применим.

**2.4.** Нужны ли слоты, которых сейчас нет: `linux-arm64`, `win-x86`, `win-arm64`, `osx`
раздельно по архитектурам?

---

## 3. Параметры wasm-сборки

**3.1.** В `documentation/wasm-symbol-renaming.md` §6.2 упоминаются оба закреплённых образа
emsdk — `3.1.34` и `3.1.39`. Какой из них давал `.a`, который реально заработал в Unity?

**3.2.** Unity линкует своим форком тулчейна (`Unity-Technologies/llvm-project`, clang 17.0.0),
а наш `scripts/Docker/wasm/Dockerfile` ставит ванильный `emsdk install 3.1.39`. Проверялась ли
линковка именно ванильной сборки `.a` Unity-тулчейном, или `.a` собирался тулчейном из Unity?
Если проверялась — были ли расхождения?

**3.3.** Куда физически клали `libSkiaSharp.a` и `libHarfBuzzSharp.a` в Unity-проекте при
проверке? (В `Assets/ExternalPlugins/WebGL/` уже лежат draco-архивы — платформа там назначается
именем каталога.)

**3.4.** Сколько по времени и сколько диска занимает полная wasm-сборка с
`--wasmRenameThirdPartySymbols=true`? Отдельно — сколько занимает
`--target=generate-wasm-harfbuzz-symbol-renames`. Нужно для выбора раннера.

---

## 4. Managed-сборки и их приземление в Unity

`SkiaSharp.dll` с `__Internal` и обычный `SkiaSharp.dll` — это две сборки с одинаковым именем.
Чтобы они ужились, у обычной надо снять WebGL из настроек плагина, а это хранится в `.meta`.
Но `Assets/ExternalDependencies` целиком в `.gitignore`, и `.meta` там пересоздаются при каждом
импорте — то есть закоммитить настройку негде.

**4.1.** Как вы это решали при проверке? Руками в Inspector каждый раз, или есть механизм,
которого мы не нашли?

**4.2.** Приемлема ли правка `SoftSmile.Vision.UnityApp.csproj` — перестать копировать
`SkiaSharp`/`HarfBuzzSharp` в `Assets/ExternalDependencies`, чтобы они приезжали из
версионированного пакета? Без этого версия остаётся файлом, который кто-то положил, и
рассинхрон, ради которого всё затевается, никуда не денется.

**4.3.** В `documentation/unity-webgl-internal-pinvoke.md` упомянут постбилдовый IL-патч
`DLLPInvokeRewriter.RewritePInvoke` на Mono.Cecil. В репозитории `vision` мы его не нашли.
Где он живёт и надо ли его убирать после перехода на `__Internal`-сборки?

**4.4.** Рассматривался ли UPM-пакет (Unity Package Manager) как способ поставки? В пакете
`.meta` — его часть, платформенные настройки едут вместе с DLL, а версия становится строкой
в `Packages/manifest.json`, видимой в code review.

---

## 5. Известная дыра §6 (C++-интерналы harfbuzz)

В `documentation/wasm-symbol-renaming.md` §6 зафиксировано: C++-интерналы harfbuzz (шаблоны,
конструкторы/деструкторы) не переименованы и не спрятаны, порядка тысячи имён совпадают с тем,
что несёт Unity, а коллизии сейчас нет только потому, что dead-code elimination выбрасывает
ветку AAT-шрифтов. Формулировка в документе — «fragile, not fixed».

**5.1.** Есть ли конкретное число: сколько сейчас mangled-символов (`_Z...`) без префикса
`sksharp_` в готовом `libHarfBuzzSharp.a`? Нужно как базовая линия — сторож из §6.3.3 имеет
смысл только если падает на **росте** относительно записанного значения, а не на самом факте.

**5.2.** Известен ли конкретный шрифт или сценарий, который снова втянет AAT-ветку и вернёт
коллизию? Если да — это готовый регрессионный тест.

**5.3.** Путь §6.3.1 (namespace-wrap плюс патч `hb-cplusplus.hh`) — планируется ли им
заниматься, и в каком горизонте? Мы хотим понимать, закладывать ли CI под то, что дыра
закроется, или строить приёмку исходя из того, что она останется.

**5.4.** Фраза «verified end-to-end against a real Unity 6000.3.8f1 WebGL project» — что именно
проверялось? Успешная линковка, или плеер собирался и работал в браузере? Если работал — какой
сценарий прогоняли?

---

## 6. Приёмка

**6.1.** Какая минимальная проверка убедит вас, что собранный бандл валиден и им можно
пользоваться? Мы предполагаем три уровня и хотим понять, где проходит граница «можно
публиковать»:

- `nm`/`emnm` по архиву: неперeименованных `FT_*`/`png_*`/`jpeg_*` нет, `sksharp_*` есть,
  `sk_*` не затронуты;
- сборка Unity WebGL-плеера на этом бандле (существующая джоба `build AWS Web DFA`);
- деплой на dev и ручная проверка в браузере.

**6.2.** Есть ли смысл прикладывать к бандлу сгенерированные заголовки переименований
(`wasm_symbol_renames.h`, `wasm_symbol_aliases.h`) как доказательство, чем именно собран
архив? Или это лишний вес?

---

## Что мы уже решили на своей стороне

Чтобы было видно рамку, в которой задаются вопросы:

- CI живёт в GitHub Actions на собственном self-hosted раннере; GitLab остаётся на приёмке
  и деплое Web DFA.
- Команда запуска wasm-сборки не меняется:
  `bash scripts/Docker/wasm/build-local.sh <emscripten> --wasmRenameThirdPartySymbols=true --emscriptenFeatures=<features>`.
- Существующие скрипты сборки (`scripts/Docker/**`, `native/**`, `*.cake`) не трогаем.
- Только конфигурация Release.
- Сборка запускается вручную с обязательным параметром «какую ветку собирать» плюс
  автоматически на пуш тега вида `v*-ss.*`. Это нужно, потому что новые версии SkiaSharp
  приезжают черри-пиком наших коммитов на новую release-ветку.
- Версия бандла берётся из git-тега форка; одна и та же строка попадает в имя артефакта,
  в манифест `versions.json` и в имя публикуемого пакета.
