#!/usr/bin/env python3
"""Patch Uncharted's bb-probe.exe so CrossOver on macOS can reserve its guest memory.

macOS keeps a guard over 0x1000000000, which is where this runtime asks Windows
for the PlayStation 4 address window. The prepared game image is relocatable,
so the window can start at 0x7000000000 instead. The same executable is also
hooked to a small DLL that accepts TLS slots Wine puts past the first 64.
"""
import argparse
import hashlib
import struct
from pathlib import Path

PROBE_SHA256 = "993357964b408a23a242fba47c14a3086b0ec25ee3ade30b9e2efca3774d9d8e"
TLS_SLOT_FILE = 0xCE9320
TLS_GUARD_FILE = 0x1DA34

USER_MIN = 0x1000000000
USER_MAX = 0xFC00000000
COMPAT_MIN = 0x7000000000
PATCH_TCB_RVA = 0x5480
IMAGE_GLOBAL_RVA = 0xCF3D08
DLL_NAME = b"uncharted-crossover-tls.dll\0"
EXPORT_NAME = b"\0\0patch_guest_tls\0"

# Immediate operand file offsets in this 0.3.3 bb-probe.exe. The two opcode
# bytes sit immediately before each immediate.
PATCHES = (
    (0xE92F, b"\x48\xbf", USER_MAX - USER_MIN, USER_MAX - COMPAT_MIN, "reservation size"),
    (0xE939, b"\x48\xbe", USER_MIN, COMPAT_MIN, "reservation base"),
    (0xF57B, b"\x49\xbe", USER_MIN + 1, COMPAT_MIN + 1, "low-map ceiling"),
    (0x10AE6, b"\x48\xb9", USER_MIN, COMPAT_MIN, "placement floor"),
    (0x34EDF, b"\x48\xb8", USER_MIN, COMPAT_MIN, "GPU address floor"),
)


def align(value, boundary):
    return (value + boundary - 1) // boundary * boundary


def patch(source: Path, destination: Path) -> None:
    data = bytearray(source.read_bytes())
    digest = hashlib.sha256(data).hexdigest()
    if digest != PROBE_SHA256:
        raise ValueError(f"This bb-probe.exe is not the 0.3.3 runtime ({digest})")
    if data[TLS_SLOT_FILE:TLS_SLOT_FILE + 4] != b"\xff" * 4:
        raise ValueError("Guest TLS slot is not the expected unset value")
    if data[TLS_GUARD_FILE:TLS_GUARD_FILE + 2] != b"\x73\x0d":
        raise ValueError("TLS slot guard is not the expected jump")
    # TlsSetValue accepts expansion slots. The adapter installs those loads.
    data[TLS_GUARD_FILE:TLS_GUARD_FILE + 2] = b"\x90\x90"
    for offset, opcode, old, new, label in PATCHES:
        expected = opcode + struct.pack("<Q", old)
        found = bytes(data[offset - 2:offset + 8])
        if found != expected:
            raise ValueError(f"{label} does not match this bb-probe.exe ({found.hex()})")
        data[offset:offset + 8] = struct.pack("<Q", new)
    _hook_tls(data)
    _enlarge_record_chunks(data)
    _translate_menu(data)
    _coalesce_depth_sync(data)
    _round_arena_binds(data)
    _claim_shadow_blocks(data)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    temporary.write_bytes(data)
    temporary.replace(destination)


def _enlarge_record_chunks(data: bytearray) -> None:
    """One recorded GPU command during combat exceeds the 128 KB chunk.

    Commands live in the first 0x20000 bytes. The cursor and two neighboring
    qwords follow, and the allocation is 0x20040. ReserveRecordData aborts
    when one reservation cannot fit. The data area becomes 4 MB and those
    three qwords move with it.
    """
    old_cap, new_cap = 0x20000, 0x400000
    delta = new_cap - old_cap
    text_start, text_end = 0x400, 0x400 + 0x53A600
    text = bytes(data[text_start:text_end])
    changed = 0
    cursors = []

    def rewrite(at, new):
        nonlocal changed
        data[at:at + 4] = struct.pack("<I", new)
        changed += 1

    for field in (0x20000, 0x20008, 0x20010):
        raw = struct.pack("<I", field)
        index = 0
        while True:
            found = text.find(raw, index)
            if found < 0:
                break
            index = found + 1
            at = text_start + found
            if not _is_chunk_field(data, at):
                continue
            if field == old_cap:
                cursors.append(at)
            rewrite(at, field + delta)

    index = 0
    cap = struct.pack("<I", old_cap)
    while True:
        found = text.find(cap, index)
        if found < 0:
            break
        index = found + 1
        at = text_start + found
        near_cursor = any(at - 32 <= cursor < at for cursor in cursors)
        if near_cursor and _is_capacity_compare(data, at):
            rewrite(at, new_cap)
        elif data[at - 2:at] == b"\x41\xb8" and data[at + 4:at + 7] == b"\x4c\x2b\x80":
            rewrite(at, new_cap)

    allocs = 0
    alloc = struct.pack("<I", 0x20040)
    index = 0
    while True:
        found = text.find(alloc, index)
        if found < 0:
            break
        index = found + 1
        at = text_start + found
        if data[at - 1] in range(0xB8, 0xC0) or data[at - 2:at] == b"\x41\xb8":
            rewrite(at, 0x400040)
            allocs += 1
    limit_at = text.find(struct.pack("<I", 0x20001))
    if limit_at < 0 or data[text_start + limit_at - 3:text_start + limit_at] != b"\x48\x81\xfa":
        raise ValueError("record chunk limit was not the expected compare")
    rewrite(text_start + limit_at, 0x400001)
    if len(cursors) < 50 or allocs != 12:
        raise ValueError(f"record chunk patch saw {len(cursors)} cursors and {allocs} allocations")


def _is_chunk_field(data: bytearray, at: int) -> bool:
    opcodes = {0x8B, 0x89, 0x2B, 0x81, 0x83, 0xC7, 0x03, 0x01, 0x29, 0x39}
    rex, opcode, modrm = data[at - 3], data[at - 2], data[at - 1]
    if rex in range(0x40, 0x50) and opcode in opcodes and modrm >> 6 == 2 and (modrm & 7) != 4:
        if (modrm & 7) == 5 and (rex & 1) == 0:
            return False
        return True
    rex, opcode, modrm, sib = data[at - 4], data[at - 3], data[at - 2], data[at - 1]
    if rex in range(0x40, 0x50) and opcode in opcodes and modrm >> 6 == 2 and (modrm & 7) == 4:
        base = sib & 7
        if base == 4 and (rex & 1) == 0:
            return False
        if base == 5 and (rex & 1) == 0:
            return False
        return True
    # movaps [r13+cursor], xmm — the recorder clears the cursor this way.
    return data[at - 4:at] == b"\x41\x0f\x29\xb5"


def _is_capacity_compare(data: bytearray, at: int) -> bool:
    rex, opcode, modrm = data[at - 3], data[at - 2], data[at - 1]
    if rex in range(0x40, 0x50) and opcode == 0x81 and modrm >> 6 == 3 and (modrm >> 3) & 7 == 7:
        return True
    return data[at - 2:at] == b"\x48\x3d"


def _hook_tls(data: bytearray) -> None:
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    coff = pe + 4
    section_count = struct.unpack_from("<H", data, coff + 2)[0]
    optional = coff + 20
    optional_size = struct.unpack_from("<H", data, coff + 16)[0]
    if struct.unpack_from("<H", data, optional)[0] != 0x20B:
        raise ValueError("bb-probe.exe is not a PE32+ image")
    section_alignment, file_alignment = struct.unpack_from("<II", data, optional + 32)
    header_table = optional + optional_size
    header_slot = header_table + section_count * 40
    size_of_headers = struct.unpack_from("<I", data, optional + 60)[0]
    if header_slot + 40 > size_of_headers or any(data[header_slot:header_slot + 40]):
        raise ValueError("No room for a TLS hook section")

    layouts = []
    for index in range(section_count):
        header = header_table + index * 40
        virtual_size, rva, raw_size, raw_offset = struct.unpack_from("<IIII", data, header + 8)
        layouts.append((rva, max(virtual_size, raw_size), raw_offset))

    def file_offset(rva):
        for start, size, raw in layouts:
            if start <= rva < start + size:
                return raw + rva - start
        raise ValueError(f"RVA {rva:#x} is outside the original sections")

    import_directory = optional + 112 + 8
    import_rva, _import_size = struct.unpack_from("<II", data, import_directory)
    cursor = file_offset(import_rva)
    descriptors = []
    while any(data[cursor:cursor + 20]):
        descriptors.append(bytes(data[cursor:cursor + 20]))
        cursor += 20

    section_rva = align(max(start + size for start, size, _raw in layouts), section_alignment)
    raw_offset = align(len(data), file_alignment)
    descriptor_size = (len(descriptors) + 2) * 20
    lookup_offset = align(descriptor_size, 8)
    iat_offset = lookup_offset + 16
    name_offset = iat_offset + 16
    symbol_offset = align(name_offset + len(DLL_NAME), 2)
    code_offset = align(symbol_offset + len(EXPORT_NAME), 16)

    section = bytearray(code_offset + 32)
    struct.pack_into(
        "<IIIII", section, 0,
        section_rva + lookup_offset, 0, 0,
        section_rva + name_offset, section_rva + iat_offset)
    for index, descriptor in enumerate(descriptors, start=1):
        section[index * 20:(index + 1) * 20] = descriptor
    struct.pack_into("<Q", section, lookup_offset, section_rva + symbol_offset)
    struct.pack_into("<Q", section, iat_offset, section_rva + symbol_offset)
    section[name_offset:name_offset + len(DLL_NAME)] = DLL_NAME
    section[symbol_offset:symbol_offset + len(EXPORT_NAME)] = EXPORT_NAME

    code_rva = section_rva + code_offset
    image_disp = IMAGE_GLOBAL_RVA - (code_rva + 11)
    iat_disp = (section_rva + iat_offset) - (code_rva + 20)
    code = (
        b"\x48\x83\xEC\x28"
        + b"\x48\x8B\x05" + struct.pack("<i", image_disp)
        + b"\x4C\x8B\xC0"
        + b"\xFF\x15" + struct.pack("<i", iat_disp)
        + b"\x48\x83\xC4\x28"
        + b"\xC3"
    )
    section[code_offset:code_offset + len(code)] = code

    prologue = file_offset(PATCH_TCB_RVA)
    if data[prologue:prologue + 5] != bytes.fromhex("5541565657"):
        raise ValueError("patch_tcb_loads prologue changed")
    data[prologue:prologue + 5] = b"\xE9" + struct.pack("<i", code_rva - (PATCH_TCB_RVA + 5))

    virtual_size = code_offset + len(code)
    raw_size = align(virtual_size, file_alignment)
    data[header_slot:header_slot + 40] = struct.pack(
        "<8sIIIIIIHHI", b".umac\0\0\0", virtual_size, section_rva,
        raw_size, raw_offset, 0, 0, 0, 0, 0xE0000060)
    struct.pack_into("<H", data, coff + 2, section_count + 1)
    struct.pack_into("<I", data, optional + 56, align(section_rva + virtual_size, section_alignment))
    struct.pack_into("<II", data, import_directory, section_rva, descriptor_size)
    struct.pack_into("<I", data, optional + 64, 0)
    data.extend(bytes(raw_offset - len(data)))
    data.extend(section)
    data.extend(bytes(raw_size - len(section)))


# The settings overlay in this port is compiled in Russian. Each replacement
# is a C string, so the English text has to fit in the original bytes.
MENU_ENGLISH = (
    ("Bloodborne — настройки  (Insert / L3+R3)", "Settings (Insert / L3+R3)"),
    ("%.0f FPS  (%.1f мс)", "%.0f FPS  (%.1f ms)"),
    ("Временной апскейлер", "Temporal upscaler"),
    ("Выкл", "Off"),
    ("TAA (нативное сглаживание)", "TAA (native)"),
    ("Апскейлер", "Upscaler"),
    ("— не поддерживается видеокартой", "— not supported by this GPU"),
    ("— в работе", "— in use"),
    ("FSR 4 недоступен: %s", "FSR 4 unavailable: %s"),
    ("Активен режим, выбранный выше. FSR 4 можно выбрать снова.",
     "The mode selected above is active. You can choose FSR 4 again."),
    ("FSR 4.1.1 в режиме INT8: модель из DLL AMD 4.1.1, воспроизведённая в Vulkan (результат совпадает с DLL). Одна модель для Native..Performance и отдельная для Ultra Performance. Ассеты: tools/fsr4cap/build_assets.sh (нужны DLL и Proton).",
     "FSR 4.1.1 INT8 replays an AMD 4.1.1 DLL on Vulkan. One model covers Native through Performance, and another covers Ultra Performance."),
    ("FSR 4 в режиме INT8 (модель v07 из исходников AMD FidelityFX SDK). Качество выше, чем у FSR 3.1, но проход тяжелее. Смена пресета пересобирает модель (короткая пауза). Ассеты: tools/fetch_fsr4_assets.sh.",
     "FSR 4 INT8 (FidelityFX SDK model v07). Sharper than FSR 3.1 and heavier. Changing the preset rebuilds the model."),
    ("FSR 4: авто-экспозиция", "FSR 4: auto exposure"),
    ("FSR 4: обратный знак jitter", "FSR 4: invert jitter"),
    ("Проверка при гостинге: сеть FSR 4 нормирует цвет по экспозиции и по ней решает, когда отбросить прошлые кадры. Меняются сразу, без перезапуска.",
     "FSR 4 uses exposure to decide when to drop old frames. This applies immediately."),
    ("Пресет", "Preset"),
    ("%s (x%.1f, рендер %dx%d)", "%s (x%.1f, render %dx%d)"),
    ("TAA сглаживает сцену в разрешении вывода, без модели FSR и апскейлинга. Сохранённый пресет FSR восстановится при выборе FSR.",
     "TAA smooths the scene at the output resolution, without an FSR model. Choosing FSR again restores the saved FSR preset."),
    ("Активный рендер сцены: %d x %d", "Scene render: %d x %d"),
    ("Пресет при запуске: %s", "Startup preset: %s"),
    ("При выводе не 1080p вся игра рисуется в разрешении пресета (патч при запуске): это быстрее всего на Steam Deck и слабых GPU. Смена пресета или разрешения вывода — после перезапуска. Пункт «Смена разрешения на лету» ниже включает смену без перезапуска (постобработка тогда остаётся в 1080p, медленнее).",
     "Below 1080p the scene is drawn at the preset size, which is faster on a weak GPU. Changing the preset or output size needs a restart unless live resolution is on. Live changes keep post-processing at 1080p and cost more."),
    ("BB_RENDER_RES фиксирует размер сцены при запуске. Уберите эту явную переменную для смены разрешения и пресетов без перезапуска игры.",
     "BB_RENDER_RES locks the scene size at startup. Remove it to change resolution and presets without restarting."),
    ("Native AA: FSR работает как сглаживание. Остальные пресеты уменьшают разрешение отрисовки сцены относительно вывода. Интерфейс рисуется в разрешении вывода. Пресет применяется со следующего кадра без перезапуска игры.",
     "Native AA uses FSR as anti-aliasing. Other presets draw the scene below the output size. The interface stays at the output size. The preset applies on the next frame."),
    ("Резкость (RCAS)", "Sharpness (RCAS)"),
    ("Сила резкости", "Sharpness"),
    ("До 1 — резкость самого апскейлера (RCAS). Выше 1 добавляется ещё один проход RCAS. Ctrl+клик по ползунку — ввести точное значение.",
     "Up to 1 is the upscaler's own sharpness. Above 1 adds another pass. Ctrl-click the slider to type a value."),
    ("Субпиксельный сдвиг (jitter)", "Sub-pixel jitter"),
    ("Каждый кадр сцена сдвигается на долю пикселя, и апскейлер собирает из нескольких кадров больше деталей. Без него получается только сглаживание по истории.",
     "Each frame shifts the scene by a fraction of a pixel so the upscaler can recover detail. Without it, only history-based smoothing remains."),
    ("Маска реактивности", "Reactive mask"),
    ("Включить маску", "Enable mask"),
    ("Помечает прозрачные эффекты (частицы, дымку), чтобы апскейлер меньше опирался на прошлые кадры. Меньше шлейфов за эффектами, но под ними возвращается дрожание.",
     "Marks particles and haze so the upscaler relies less on previous frames. Effects trail less, but the area under them can shimmer."),
    ("Масштаб", "Scale"),
    ("Порог", "Threshold"),
    ("Максимум", "Maximum"),
    ("Показать маску (отладка)", "Show mask (debug)"),
    ("Векторы движения персонажей", "Character motion vectors"),
    ("Точные векторы для анимированных объектов: одежда и оружие меньше рассыпаются при движении. Статичная сцена не получает дополнительный проход. Изменение применяется после перезапуска игры.",
     "Motion vectors for animated objects, so cloth and weapons smear less. A static scene skips the extra pass. Applies after a restart."),
    ("Показать векторы движения (отладка)", "Show motion vectors (debug)"),
    ("Красный/зелёный: движение по горизонтали/вертикали (8 пикселей = полная яркость). Синий: пиксель получил точный вектор объекта, а не только движение камеры. Движущийся предмет без синего и без красного/зелёного апскейлер считает неподвижным, отсюда шлейф.",
     "Red and green are horizontal and vertical motion. Blue means the pixel has an object vector, not only camera motion. A moving object with neither is treated as still and leaves a trail."),
    ("Генерация кадров", "Frame generation"),
    ("FSR 3 (любая видеокарта)", "FSR 3 (any GPU)"),
    ("Кадры между двумя кадрами игры: 60 FPS на экране становятся 120. Нужны представление Mailbox или Immediate и монитор с такой частотой. Немного добавляет задержку ввода. Меню и видеоролики не генерируются.",
     "Draws frames between the game's frames, so 60 FPS displays as 120. Needs Mailbox or Immediate presentation and a display at that refresh rate. Adds a little input latency. Menus and videos are left as they are."),
    ("Множитель", "Multiplier"),
    ("Разрешение вывода", "Output resolution"),
    ("Размер готового кадра и интерфейса. Пресет задаёт размер сцены относительно вывода: 4K Performance = 1920x1080. Применяется после перезапуска игры.",
     "Size of the finished frame and the interface. The preset sets the scene size relative to that. 4K Performance = 1920x1080. Applies after a restart."),
    ("Размер готового кадра и интерфейса меняется на границе следующего кадра. Пресет задаёт размер сцены относительно вывода: 4K Performance = 1920x1080. Смена размера сбрасывает историю FSR и может вызвать короткую паузу.",
     "The finished frame and interface change on the next frame. The preset sets the scene size. 4K Performance = 1920x1080. Changing the size clears FSR history and can hitch briefly."),
    ("Авто (по видеокарте)", "Auto (by GPU)"),
    ("Выключена (быстрее)", "Off (faster)"),
    ("Включена", "On"),
    ("Смена разрешения на лету", "Live resolution"),
    ("Включена: разрешение вывода и пресет меняются без перезапуска, но постобработка игры остаётся в 1080p — на Steam Deck и старых видеокартах это заметно медленнее. Выключена: всё рисуется в разрешении пресета, смена — через перезапуск. Авто включает её на мощных дискретных видеокартах. Применяется после перезапуска игры.",
     "On: output size and preset change without a restart, but game post-processing stays at 1080p and costs more on a weak GPU. Off: everything is drawn at the preset size and changes need a restart. Auto turns it on for a fast discrete GPU. Applies after a restart."),
    ("Эффекты игры (после перезапуска)", "Game effects (after restart)"),
    ("Максимальная (-2)", "Highest (-2)"),
    ("Как в игре", "In-game"),
    ("Ниже (1)", "Lower (1)"),
    ("Минимальная (2)", "Lowest (2)"),
    ("Детализация моделей", "Model detail"),
    ("Эффекты включаются и выключаются патчами игры при запуске (patches/Bloodborne.xml). Размытие в движении и тени от динамических источников заметно нагружают GPU.",
     "These toggles apply Bloodborne patches at startup (patches/Bloodborne.xml). They do not change Uncharted. Motion blur and dynamic shadows cost GPU time."),
    ("Свободная камера: удерживайте Cross и нажимайте L3 (клавиатура: Space + Z). Debug menu: левый touchpad / Tab. Нужны DbgFont14h.ccm и DbgFont14h.tpf в dvdroot_ps4/font из мода Nexus #253. Правый touchpad: Backspace.",
     "Free camera: hold Cross and press L3 (keyboard: Space + Z). Debug menu: left touchpad or Tab. Needs font files from a Bloodborne mod. Right touchpad: Backspace."),
    ("Изменения применятся после перезапуска игры", "Changes apply after the game restarts"),
    ("Применить и перезапустить игру", "Apply and restart"),
    ("Прочее", "Other"),
    ("Счётчик FPS в углу", "FPS counter"),
    ("Закрыть", "Close"),
    ("Настройки сохраняются в bbport.ini", "Settings are saved in bbport.ini"),
    ("Хроматическая аберрация", "Chromatic aberration"),
    ("Глубина резкости (DoF)", "Depth of field (DoF)"),
    ("Размытие в движении", "Motion blur"),
    ("Затенение SSAO", "SSAO"),
    ("Собственное сглаживание игры", "Game anti-aliasing"),
    ("Тени от динамических источников", "Dynamic shadows"),
    ("Отражения SSR (не было в игре)", "SSR (not in the original)"),
    ("Пропуск заставок при запуске", "Skip startup logos"),
    ("Свободная камера (Cross + L3)", "Free camera (Cross + L3)"),
    ("Debug menu (нужны файлы шрифтов)", "Debug menu (needs font files)"),
    ("Чит: бессмертие (не ниже 1 HP)", "Cheat: no death (at least 1 HP)"),
    ("Чит: враги не замечают", "Cheat: enemies ignore you"),
    ("Чит: враги не слышат", "Cheat: enemies cannot hear"),
    ("Чит: Rally не угасает", "Cheat: Rally does not decay"),
    ("Чит: управление врагом (R3 / L3)", "Cheat: control an enemy (R3 / L3)"),
    ("Без Rally (возврата HP)", "No Rally (HP regain)"),
    ("Камера дальше", "Camera farther"),
    ("Без автоповорота камеры", "No automatic camera turn"),
    ("Бег с меньшим наклоном стика", "Run with less stick tilt"),
    ("Физика тел как в Dark Souls", "Dark Souls body physics"),
    ("%.0f FPS  %.1f мс  %s", "%.0f FPS  %.1f ms  %s"),
)


def _depth_sync_cave(cave_va: int) -> bytearray:
    """Skip SyncImageToBuffer when this frame already synced that address.

    OnGuestFlip bumps g_guest_frames once per presented frame. The large
    depth copies repeat the same addresses inside that frame, and each one
    waited on the GPU. The first wait still runs, so depth of field stays
    on the current picture. A new address, or a full table, still syncs.
    The remembered addresses live in writable BSS. The text page is not.
    """
    code = bytearray()
    labels = {}
    frames_va = 0x14361D898
    sync_va = 0x14020AF30

    def mark(name):
        labels[name] = len(code)

    def emit(*raw):
        for item in raw:
            code.extend(item if isinstance(item, (bytes, bytearray)) else bytes([item]))

    def rip(at, target, end):
        # end is how many bytes of this instruction follow the displacement.
        return struct.pack("<i", target - (cave_va + at + end))

    emit(0x44, 0x8B, 0x15)
    frames_at = len(code)
    emit(b"\0\0\0\0")
    emit(0x44, 0x3B, 0x15)
    cmp_frame_at = len(code)
    emit(b"\0\0\0\0")
    emit(0x74, 0)
    je_same_at = len(code) - 1
    emit(0x44, 0x89, 0x15)
    mov_frame_at = len(code)
    emit(b"\0\0\0\0")
    emit(0xC7, 0x05)
    mov_count_at = len(code)
    emit(b"\0\0\0\0\0\0\0\0")
    mark("same")
    emit(0x45, 0x31, 0xDB)
    emit(0x48, 0x8D, 0x05)
    lea_at = len(code)
    emit(b"\0\0\0\0")
    mark("loop")
    emit(0x44, 0x3B, 0x1D)
    cmp_count_at = len(code)
    emit(b"\0\0\0\0")
    emit(0x73, 0)
    jae_insert_at = len(code) - 1
    emit(0x4A, 0x3B, 0x14, 0xD8)
    emit(0x74, 0)
    je_skip_at = len(code) - 1
    emit(0x41, 0xFF, 0xC3)
    emit(0xEB, 0)
    jmp_loop_at = len(code) - 1
    mark("insert")
    emit(0x41, 0x83, 0xFB, 0x08)
    emit(0x73, 0)
    jae_call_at = len(code) - 1
    emit(0x4A, 0x89, 0x14, 0xD8)
    emit(0xFF, 0x05)
    inc_count_at = len(code)
    emit(b"\0\0\0\0")
    mark("call")
    emit(0xE9)
    jmp_sync_at = len(code)
    emit(b"\0\0\0\0")
    mark("skip")
    emit(0xC3)
    while len(code) % 8:
        emit(0x90)
    # The table sits in this executable page, so the section is made writable.
    frame_va = cave_va + len(code)
    count_va = frame_va + 4
    addrs_va = frame_va + 8

    def near(at, name):
        code[at] = (labels[name] - (at + 1)) & 0xFF

    near(je_same_at, "same")
    near(jae_insert_at, "insert")
    near(je_skip_at, "skip")
    near(jmp_loop_at, "loop")
    near(jae_call_at, "call")
    code[frames_at:frames_at + 4] = rip(frames_at, frames_va, 4)
    code[cmp_frame_at:cmp_frame_at + 4] = rip(cmp_frame_at, frame_va, 4)
    code[mov_frame_at:mov_frame_at + 4] = rip(mov_frame_at, frame_va, 4)
    # The immediate zero follows this displacement, so RIP is 8 bytes on.
    code[mov_count_at:mov_count_at + 4] = rip(mov_count_at, count_va, 8)
    code[lea_at:lea_at + 4] = rip(lea_at, addrs_va, 4)
    code[cmp_count_at:cmp_count_at + 4] = rip(cmp_count_at, count_va, 4)
    code[inc_count_at:inc_count_at + 4] = rip(inc_count_at, count_va, 4)
    code[jmp_sync_at:jmp_sync_at + 4] = rip(jmp_sync_at, sync_va, 4)
    code.extend(b"\0" * (8 + 64))
    return code


def _coalesce_depth_sync(data: bytearray) -> None:
    image = 0x140000000
    text_va, text_raw, text_vsize = 0x1000, 0x400, 0x53A4D6
    cave_va = image + text_va + text_vsize
    cave = _depth_sync_cave(cave_va)
    if text_vsize + len(cave) > 0x53A600:
        raise ValueError("depth-sync cave does not fit in the text section")

    call_va = 0x14027C685
    call_file = text_raw + (call_va - image - text_va)
    call = bytes(data[call_file:call_file + 5])
    if call != bytes.fromhex("e8a6e8f8ff"):
        raise ValueError(f"depth sync call does not match this probe ({call.hex()})")
    data[call_file:call_file + 5] = b"\xe8" + struct.pack("<i", cave_va - (call_va + 5))

    pe = struct.unpack_from("<I", data, 0x3C)[0]
    opt = struct.unpack_from("<H", data, pe + 20)[0]
    section = pe + 24 + opt
    name = bytes(data[section:section + 8]).split(b"\0", 1)[0]
    vsize, virtual, rawsize = struct.unpack_from("<III", data, section + 8)
    if name != b".text" or vsize != text_vsize or virtual != text_va or rawsize != 0x53A600:
        raise ValueError("text section is not the expected size")
    struct.pack_into("<I", data, section + 8, text_vsize + len(cave))
    # The remembered addresses are stored in this page.
    characteristics = struct.unpack_from("<I", data, section + 36)[0]
    struct.pack_into("<I", data, section + 36, characteristics | 0x80000000)
    file_at = text_raw + text_vsize
    if any(byte not in (0x00, 0xCC) for byte in data[file_at:file_at + len(cave)]):
        raise ValueError("depth-sync cave overlaps existing code")
    data[file_at:file_at + len(cave)] = cave


# EnsureResident binds whatever 16 KB blocks one request touches. On KosmicKrisp
# each bind becomes a Metal 4 sparse mapping update on the graphics queue, about
# two thousand of them by the bar fight in Drake's Deception. Rounding the
# request out to this granule, inside the arena, leaves a few dozen, almost all
# while loading.
BIND_GRANULE = 64 << 20


def _round_arena_binds(data: bytearray) -> None:
    """Widen EnsureResident(buffer, first, last) to whole granules.

    The blocks are guest addresses shifted by the block size at
    BufferCache+0x3A80. The buffer holds its guest base at +0 and its size at
    +8, so the widened range is clamped to that arena. Only the GPU backing
    and page table change; guest data is still uploaded when it is used.
    """
    image = 0x140000000
    text_va, text_raw = 0x1000, 0x400
    site_va, resume_va = 0x140208A73, 0x140208A79
    site_file = text_raw + (site_va - image - text_va)
    site = bytes(data[site_file:site_file + 6])
    if site != bytes.fromhex("49ffc14d39c8"):
        raise ValueError(f"EnsureResident range check does not match this probe ({site.hex()})")

    pe = struct.unpack_from("<I", data, 0x3C)[0]
    opt = struct.unpack_from("<H", data, pe + 20)[0]
    section = pe + 24 + opt
    vsize = struct.unpack_from("<I", data, section + 8)[0]
    cave_rva = text_va + align(vsize, 16)
    cave_va = image + cave_rva
    cave = bytearray(bytes.fromhex(
        "4c8b12"          # mov r10, [rdx]            arena base
        "4c8b5a08"        # mov r11, [rdx+8]          arena size
        "4d01d3"          # add r11, r10
        "49ffcb"          # dec r11
        "0fb68e803a0000"  # movzx ecx, byte [rsi+0x3a80]
        "49d3ea"          # shr r10, cl
        "49d3eb"          # shr r11, cl
        "b8") + struct.pack("<I", BIND_GRANULE) + bytes.fromhex(
        "48d3e8"          # shr rax, cl
        "48ffc8"          # dec rax                   granule mask
        "4889c1"          # mov rcx, rax
        "48f7d1"          # not rcx
        "4921c8"          # and r8, rcx
        "4d39d0"          # cmp r8, r10
        "4d0f42c2"        # cmovb r8, r10
        "4909c1"          # or r9, rax
        "4d39d9"          # cmp r9, r11
        "4d0f47cb"        # cmova r9, r11
        "4889f1"          # mov rcx, rsi
        "49ffc1"          # inc r9
        "4d39c8"          # cmp r8, r9
        "e9"))
    cave += struct.pack("<i", resume_va - (cave_va + len(cave) + 4))
    if cave_rva - text_va + len(cave) > 0x53A600:
        raise ValueError("arena-bind cave does not fit in the text section")
    file_at = text_raw + cave_rva - text_va
    if any(byte not in (0x00, 0xCC) for byte in data[file_at:file_at + len(cave)]):
        raise ValueError("arena-bind cave overlaps existing code")
    data[file_at:file_at + len(cave)] = cave
    data[site_file:site_file + 6] = b"\xe9" + struct.pack("<i", cave_va - (site_va + 5)) + b"\x90"
    struct.pack_into("<I", data, section + 8, cave_rva - text_va + len(cave))


def _claim_shadow_blocks(data: bytearray) -> None:
    """Let a guest write claim its whole 64-byte block from the GPU's copy.

    When the guest touches a page holding GPU data, ShadowGpuData snapshots the
    guest bytes. DownloadMemory and SynchronizeMemory then keep the GPU's byte
    wherever the guest byte still equals the snapshot, so a store of an
    unchanged value (zero over zero) is lost. Drake's Deception's allocator
    relies on such stores and its shaders hang on the mixed result at the first
    London bar fight. Before either loop reads a snapshot {start, begin, end},
    each aligned 64-byte block with any changed byte gets the complement of the
    guest bytes, so the existing byte loops hand the whole block to the guest.
    Snapshots are discarded after these loops.
    """
    image = 0x140000000
    text_va, text_raw = 0x1000, 0x400
    sites = (
        # DownloadMemory, shadow record in rbx: mov r14, [rbx]; xor esi, esi
        (0x14020695D, 0x140206970, "4c8b3331f6", "4989da", "4c8b3331f6"),
        # SynchronizeMemory upload walk, record in r14: mov rbx, [r14]; xor r8d, r8d; jmp
        (0x14020D904, 0x14020D91E, "498b1e4531c0eb12", "4d89f2", "498b1e4531c0"),
    )
    for site_va, _, original, _, _ in sites:
        at = text_raw + site_va - image - text_va
        if bytes(data[at:at + len(original) // 2]).hex() != original:
            raise ValueError(f"shadow merge loop at {site_va:#x} does not match this probe")

    # .text has no slack left, so this goes at the end of the TLS hook section,
    # which is the last section in the file.
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    count = struct.unpack_from("<H", data, pe + 6)[0]
    optional = pe + 24
    section = optional + struct.unpack_from("<H", data, pe + 20)[0] + (count - 1) * 40
    if data[section:section + 8] != b".umac\0\0\0":
        raise ValueError("TLS hook section is not the last section")
    section_alignment, file_alignment = struct.unpack_from("<II", data, optional + 32)
    vsize, section_rva, raw_size, raw_offset = struct.unpack_from("<IIII", data, section + 8)
    if raw_offset + raw_size != len(data):
        raise ValueError("TLS hook section is not at the end of the file")
    cave_rva = section_rva + align(vsize, 16)
    cave_va = image + cave_rva
    # claim(r10 = record): preserves every register but r10.
    cave = bytearray(bytes.fromhex(
        "505152415041514153"    # push rax, rcx, rdx, r8, r9, r11
        "4d8b02"                # mov r8, [r10]             guest start
        "4d8b4a08"              # mov r9, [r10+8]           snapshot
        "4d8b5a10"              # mov r11, [r10+16]
        "4d29cb"                # sub r11, r9               count
        "31c0"                  # xor eax, eax              block start
        "4c39d8"                # .block: cmp rax, r11
        "7349"                  # jae .done
        "498d540040"            # lea rdx, [r8+rax+64]
        "4883e2c0"              # and rdx, -64
        "4c29c2"                # sub rdx, r8
        "4c39da"                # cmp rdx, r11
        "490f47d3"              # cmova rdx, r11            block end
        "4889c1"                # mov rcx, rax
        "4839d1"                # .scan: cmp rcx, rdx
        "7329"                  # jae .next
        "450fb61408"            # movzx r10d, byte [r8+rcx]
        "453a1409"              # cmp r10b, [r9+rcx]
        "7505"                  # jne .claim
        "48ffc1"                # inc rcx
        "ebeb"                  # jmp .scan
        "4889c1"                # .claim: mov rcx, rax
        "4839d1"                # .fill: cmp rcx, rdx
        "7311"                  # jae .next
        "450fb61408"            # movzx r10d, byte [r8+rcx]
        "41f7d2"                # not r10d
        "45881409"              # mov [r9+rcx], r10b
        "48ffc1"                # inc rcx
        "ebea"                  # jmp .fill
        "4889d0"                # .next: mov rax, rdx
        "ebb2"                  # jmp .block
        "415b415941585a5958"    # .done: pop r11, r9, r8, rdx, rcx, rax
        "c3"))                  # ret
    hooks = []
    for site_va, resume_va, original, load_record, replay in sites:
        stub_va = cave_va + len(cave)
        cave += bytes.fromhex("4152" + load_record + "e8")  # push r10; mov r10, record; call claim
        cave += struct.pack("<i", cave_va - (cave_va + len(cave) + 4))
        cave += bytes.fromhex("415a" + replay + "e9")       # pop r10; original loop setup; jmp
        cave += struct.pack("<i", resume_va - (cave_va + len(cave) + 4))
        hooks.append((site_va, stub_va, len(original) // 2))
    vsize = cave_rva - section_rva + len(cave)
    data.extend(bytes(raw_offset + align(vsize, file_alignment) - len(data)))
    file_at = raw_offset + cave_rva - section_rva
    data[file_at:file_at + len(cave)] = cave
    for site_va, stub_va, length in hooks:
        at = text_raw + site_va - image - text_va
        jump = b"\xe9" + struct.pack("<i", stub_va - (site_va + 5))
        data[at:at + length] = jump + b"\x90" * (length - 5)
    struct.pack_into("<II", data, section + 8, vsize, section_rva)
    struct.pack_into("<I", data, section + 16, align(vsize, file_alignment))
    struct.pack_into("<I", data, optional + 56, align(section_rva + vsize, section_alignment))


def _translate_menu(data: bytearray) -> None:
    for russian, english in MENU_ENGLISH:
        old = russian.encode("utf-8")
        new = english.encode("utf-8")
        if len(new) > len(old):
            raise ValueError(f"English label is longer than the Russian one: {english}")
        needle = old + b"\0"
        found = data.find(needle)
        if found < 0:
            raise ValueError(f"Menu string is missing: {russian}")
        while found >= 0:
            data[found:found + len(new)] = new
            data[found + len(new)] = 0
            found = data.find(needle, found + len(needle))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    patch(args.source, args.destination)
    print(args.destination)
