# blockgame

Воксельная песочница в духе Minecraft на собственном движке, написанном на [Odin](https://odin-lang.org).
Название рабочее.

Что уже есть в игре — [CHANGELOG.md](CHANGELOG.md). Что планируется — [ROADMAP.md](ROADMAP.md).

## Управление

| Клавиша | Действие |
|---|---|
| Мышь | Смотреть по сторонам |
| W A S D | Лететь вперёд / влево / назад / вправо |
| Пробел | Вверх |
| Shift | Вниз |
| Ctrl (удерживать) | Лететь быстрее |
| Esc | Выйти из игры |

FPS показывается в заголовке окна.

## Сборка (Windows)

Нужны Visual Studio Build Tools (MSVC) и Windows SDK.
Компилятор Odin кладётся в `tools\odin\` (в репозиторий не входит) или берётся из PATH.

```bat
build.bat
build\blockgame.exe
```

## Проверка производительности

```bat
cd build
blockgame.exe --bench
```

10 секунд облёта острова без ограничения кадров. Результат — в `bench.txt`,
плюс снимки экрана `bench_1.png`, `bench_2.png`, `bench_3.png`.

## Лицензия

GNU GPL v3.0 — см. [LICENSE](LICENSE).
Все текстуры нарисованы в коде игры; ресурсы Minecraft не используются.
