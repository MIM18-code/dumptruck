import SwiftUI

/// The in-app guide, reachable from the Help menu and ⌘?.
/// Plain prose about what the app does and what its words mean. This window
/// explains; it never mutates state or renders live safety verdicts.
struct HelpGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Group {
                    Text("Dumptruck help")
                        .font(.largeTitle.bold())

                    section("What this app does", """
                    Dumptruck copies camera cards to your drives and proves the \
                    copies are real. In the default Full verification, every new \
                    file is written, flushed to the disk, then read back and \
                    compared against the source, byte for byte. SAFE TO WIPE \
                    appears only when every file was verified this run on two \
                    separate physical drives and every honesty check passed. \
                    Until then the verdict says KEEP CARD.

                    Dumptruck never deletes anything from a card. The worst it can \
                    do is refuse to tell you a wipe is safe.
                    """)

                    section("Your first offload", """
                    1.  Plug in a card. It appears on the Connected shelf in \
                    the middle of the window, one tile per drive. Click Source \
                    on its tile and it moves to the left rail as the source. \
                    You can also drag a tile onto a rail. A folder can be a \
                    source too, via "Choose Source Folder…" at the bottom of \
                    the left rail or the folder button on a drive's tile.

                    2.  Click Destination on two drives' tiles. They move to \
                    the right rail. Two, because one copy on one drive is not \
                    a backup. SAFE TO WIPE requires two separate physical \
                    devices, and two partitions on the same disk do not count.

                    3.  Name the card. The name becomes the folder on every \
                    destination, and that folder is where the card's future \
                    top-ups land. Dumptruck recognizes a returning card by \
                    the files on it, not by the name; after a match it reuses \
                    the stored name automatically.

                    4.  Click Start Offload. The job card in the middle shows \
                    per-drive progress, a live speed readout, and the time left.
                    """)

                    section("Reading the verdict", """
                    SAFE TO WIPE means every file on the card was verified this \
                    run on two or more independent drives, the card did not \
                    change while it was being read, and every honesty check \
                    passed. You can format the card.

                    VERIFIED · KEEP CARD means the copies are good but the full \
                    bar was not met. Usually that is one destination instead of \
                    two, or a top-up where older files were trusted instead of \
                    re-read. The line under the verdict lists exactly what is \
                    missing.

                    UNVERIFIED — KEEP CARD and FAILED — DO NOT WIPE mean what \
                    they say. The job card keeps the reason.

                    The verdict comes from the copy engine's own attestation, \
                    never from a progress bar reaching 100%.
                    """)

                    section("Same card, more footage", """
                    You can shoot, offload, keep shooting on the same card \
                    without formatting, and offload again. Dumptruck recognizes \
                    the card and copies only the new clips into the same \
                    destination folders. Files it already verified in an earlier \
                    run are listed as "trusted" and skipped instead of copied \
                    twice.

                    A top-up job can finish green and verified while SAFE TO \
                    WIPE stays off. That is deliberate. Trusting last week's \
                    copies is not the same as reading them, so wipe permission \
                    on a continued card requires the re-verify option (Settings \
                    › Transfers), which re-reads everything.
                    """)

                    section("Batch sources", """
                    "Batch Sources…" at the bottom of the left rail queues \
                    several cards or folders in one pass. Pick the folders, \
                    review the staged list, and Dumptruck runs one job per card \
                    against the same destinations, all at once or one at a \
                    time. That switch sits at the bottom of the batch window \
                    and is the same Queueing setting as in Settings. It is \
                    built for the end of a shoot day, when there is a pile of \
                    cards and one pair of drives.

                    Dragging works the same way. Drop several cards on the \
                    left rail at once, or drop them one after another: a \
                    second card joins the first in a batch list right on the \
                    rail, and every later card joins it too. Nothing already \
                    on the rail is replaced. Cards dropped before you pick \
                    destinations wait, and are checked once you add drives. \
                    "Review Batch…" under the list opens the batch window to \
                    check labels and start.
                    """)

                    section("Loose files", """
                    Files work too. Drop a few clips from Downloads or the \
                    desktop on the left rail and they stage as one set, named \
                    by the time you dropped them; rename it like any card. The \
                    set is a folder of instant clones on this Mac's disk, so \
                    nothing is copied until you start, and the originals are \
                    never touched. A file still up in iCloud has to be \
                    downloaded before it can be dropped. Files drop flat: two \
                    files with the same \
                    name are refused rather than renamed, and files on another \
                    drive are refused too, since the drive itself should be \
                    the source there. A finished set never shows SAFE TO WIPE. \
                    There is no card to wipe, and the clones clean themselves \
                    up once the copy is verified.
                    """)
                }
                Group {
                    section("Presets and folder templates", """
                    The Presets menu at the bottom of the destinations rail \
                    saves a set of destinations so tomorrow's setup is one \
                    click. The folder template in Settings › Organize controls \
                    where cards land on each drive, for example \
                    Project/Raws/CardName. To copy into an existing folder \
                    instead, click "Choose Folder" on a destination drive's \
                    card (or press ⇧⌘O) and pick it; the same folder is \
                    used on every destination.
                    """)

                    section("Verifying old copies", """
                    The shield button in the toolbar re-checks a folder \
                    Dumptruck wrote in the past. It re-reads every file named \
                    by the sealed manifest and flags anything missing, \
                    changed, or unmanifested. Use it before you hand a drive \
                    to a client, or any time a drive has been out of your \
                    sight.
                    """)

                    section("Ejecting drives and cards", """
                    A card with a current SAFE TO WIPE verdict gets a one-click \
                    eject right on its job card. Everything else asks first, in \
                    plain words: which job is still writing or which copy is \
                    unproven, and what pulling the card now means. One click \
                    past that warning ejects. The app will not pull a card it \
                    cannot vouch for without telling you why.
                    """)

                    section("Reports", """
                    With reports on (the default), an offload writes an HTML \
                    report and a receipt into Reports/ on each destination, \
                    plus a local library copy, with clip thumbnails and the \
                    full verification record. The PDF rides along when Chrome \
                    or Chromium is installed to render it. Report writing is \
                    best effort and never touches the verdict: if a report \
                    cannot be written somewhere, the job says so and the \
                    verified copies stand. The clock \
                    button in the toolbar (or ⌘Y) opens the job history, which \
                    can export CSV and build a wrap report across a whole day \
                    of cards.
                    """)

                    section("The fun layer", """
                    The game controller button opens the Dump Yard, four small \
                    games for waiting out a long copy. Trucks drive across job \
                    cards while they run. Sounds can be turned off in Settings. \
                    None of this touches the safety logic; the verdict vocabulary \
                    stays boring on purpose.
                    """)

                    section("Menu bar and Dock", """
                    The truck in the menu bar shows active jobs and aggregate \
                    speed, and warns when a settled job needs attention. The \
                    Dock icon carries live progress and a count of running \
                    jobs; a warning badge from any job in this session \
                    outranks both, and a checkmark appears only while the \
                    staged card's SAFE verdict is current.
                    """)
                }
                Group {
                    Text("Settings, explained")
                        .font(.title.bold())
                        .padding(.top, 8)

                    section("Transfers", """
                    Verification level. Two curated bundles and a Custom \
                    escape hatch. Standard is the working DIT bar: full byte \
                    verification plus a second source read. That makes a \
                    fresh card eligible for SAFE TO WIPE; the verdict itself \
                    still requires two separate physical drives and every \
                    runtime check passing. Maximum turns everything on: \
                    prior offloads are re-read instead of trusted, and MD5, \
                    SHA-1, SHA-256 and C4 ride along with xxHash64, recorded \
                    in the receipt JSON as long as reports stay on. Maximum \
                    is required before a continuation card can earn SAFE TO \
                    WIPE, and is the right level when a delivery spec asks \
                    for specific checksums (keep reports enabled so they \
                    persist). Touching any individual control below switches \
                    the level to Custom; nothing is changed behind your back.

                    Queueing. "Off" runs every transfer at the same time. "One \
                    at a time" makes later cards wait their turn, which keeps a \
                    spinning backup drive from thrashing between two write \
                    streams. SSDs are usually fine either way.

                    Verification. "Full" re-reads every destination byte and \
                    compares it against the source. This is the mode the whole \
                    app is built around. "Fast" only checks file sizes; nothing \
                    is verified, nothing is sealed, and no verdict beyond a \
                    plain copy is possible. Fast exists for throwaway copies, \
                    not for anything you care about.

                    Re-read the source after copying. A second pass over every \
                    source file read this run, compared against the first \
                    read; with re-verify on, that covers the whole card. It \
                    is what catches \
                    a dying card or a flaky reader that returns different bytes \
                    on different reads. Turning it off forfeits SAFE TO WIPE \
                    for the run.

                    Re-verify previously offloaded files. On a top-up, re-read \
                    the old files at the destinations instead of trusting the \
                    sealed history. Slower on big continuation cards, and \
                    required before a continued card can earn SAFE TO WIPE. \
                    Also the right tool when a destination drive has been out \
                    of your hands.

                    Extra hashes. xxHash64 always runs and is what the \
                    manifests seal. MD5, SHA-1, SHA-256 and C4 can ride along \
                    at no extra disk reads, for post houses that ask for a \
                    specific format. They persist in the per-file table of \
                    each offload's receipt JSON, so reports must be on for \
                    them to outlive the job.

                    Auto-eject. Ejects the card by itself, but only after the \
                    full SAFE TO WIPE bar: complete verification on two or more \
                    physical devices. Any lesser outcome leaves the card \
                    mounted.
                    """)

                    section("Organize", """
                    The project name and folder template control where cards \
                    land on each drive, for example Project/Raws. The card \
                    name folder is always appended last. That folder is the \
                    continuation key: when the card comes back with more \
                    footage, Dumptruck finds its earlier copies by resolving \
                    the same path. Which is why date tokens do not belong in \
                    the standing template; a folder that moves every day \
                    breaks top-ups.
                    """)

                    section("Presets", """
                    A preset saves a set of destination drives plus the \
                    transfer settings that travel with them. Applying one \
                    validates that the drives are actually mounted first. It \
                    never creates folders, starts a transfer, or grants a \
                    verdict. Manage them here; apply them from the Presets \
                    menu under the destinations rail.
                    """)

                    section("Reports", """
                    Generate report: writes the HTML report and receipt after \
                    each offload, to Reports/ on each destination and a local \
                    library copy, best effort per target and never inside the \
                    sealed card folder. The PDF requires Chrome or Chromium; \
                    without one you get HTML only.

                    Clip thumbnails: first, middle and last frame per clip \
                    when the toggle is on; clips the probe cannot decode get \
                    an honest placeholder instead. \
                    "First thumbnail from frame 0" is for productions that \
                    slate at the head of the take, so the report shows the \
                    slate. "Open the report when the offload finishes" does \
                    what it says.
                    """)

                    section("Cards", """
                    Auto-select a newly mounted volume: any volume that mounts \
                    while nothing is staged gets staged and inspected \
                    automatically. Transfers still wait for you to press \
                    Start.

                    Notifications, truck sounds, and trackpad haptics are \
                    each their own toggle. Haptics need a Force Touch \
                    trackpad; a mouse feels nothing either way.

                    The HTTPS webhook posts a JSON payload when a transfer \
                    finishes, for a Slack bridge or a shop dashboard. Local \
                    paths and file names are never included, and the secret \
                    lives in the macOS Keychain, not in preferences.
                    """)

                    section("Display", """
                    Text size enlarges every label in the workbench, verdicts \
                    included. Column widths stay put, so very long names \
                    truncate rather than reflow. The menu bar toggle controls \
                    the truck in the menu bar.
                    """)

                    section("Engine", """
                    The engine is the separate copy process that does the \
                    actual reading, writing and verifying. The app you \
                    downloaded carries its own engine inside; this tab mostly \
                    matters for development, where it can point at a source \
                    checkout instead. "Test Engine" confirms the app and \
                    engine speak the same protocol version. If a strip in the \
                    main window ever says the packaged engine was not used, \
                    this is where you look.
                    """)
                }
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(minWidth: 520, idealWidth: 680, minHeight: 480, idealHeight: 760)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.bold())
            Text(body).font(.body).foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Lives inside the Help command group; a plain Button cannot reach
/// openWindow from the commands builder.
struct HelpMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Dumptruck Help") { openWindow(id: "help") }
            .keyboardShortcut("?", modifiers: [.command])
    }
}
