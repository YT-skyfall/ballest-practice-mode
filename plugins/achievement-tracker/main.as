// Achievement Tracker 0.1.0
//
// Local-progress beta for Ballest's 16 Steam achievements.
//
// The current Plugin Manager API does not expose Steam achievement unlock
// state or arbitrary Steam stats. This plugin therefore never pretends that
// locally observed progress is Steam-synced. Achievements that cannot be
// measured reliably through the public API are shown as "Steam sync needed".
//
// No Console:: access. No Steam mutations. No leaderboard or physics changes.

[Setting name="Show pinned achievement" description="Show the pinned achievement HUD while on a track."]
bool ShowPinnedHud = true;

[Setting name="Pinned HUD size" min=12 max=30 description="Text size of the pinned achievement HUD."]
float PinnedHudSize = 16;

// Colours match the Plugin Manager's current UI.
const float WINDOW_R = 0.0052f, WINDOW_G = 0.0060f, WINDOW_B = 0.0086f;
const float CARD_R = 0.0116f, CARD_G = 0.0137f, CARD_B = 0.0194f;
const float BUTTON_R = 0.0232f, BUTTON_G = 0.0273f, BUTTON_B = 0.0382f;
const float PRIMARY_R = 0.0782f, PRIMARY_G = 0.2051f, PRIMARY_B = 0.0048f;
const float MUTED_R = 0.2582f, MUTED_G = 0.2747f, MUTED_B = 0.3185f;
const float GREEN_R = 0.235f, GREEN_G = 1.0f, GREEN_B = 0.353f;
const float WARN_R = 0.8879f, WARN_G = 0.5333f, WARN_B = 0.0762f;

const double CM_PER_MILE = 160934.4;
const double SAVE_EVERY = 5.0;
const double FINISH_WAIT = 1.5;

class Achievement
{
    string id;
    string name;
    string description;
    bool trackable = false;
    double goal = 1;

    Achievement() {}

    Achievement(const string &in id, const string &in name, const string &in description, bool trackable, double goal = 1)
    {
        this.id = id;
        this.name = name;
        this.description = description;
        this.trackable = trackable;
        this.goal = goal;
    }
}

array<Achievement@> achievements;

// Persistent local evidence. These do not claim to be Steam's stored values.
int jumps = 0;
int restartActions = 0;
double distanceCm = 0;
int pbBeats = 0;

bool firstFinish = false;
bool towerFinish = false;
bool architect = false;
bool beatAuthor = false;
bool grounded = false;
bool flat20 = false;
bool glacial = false;
bool fastball = false;

// Race/session state.
int seenRestarts = 0;
int seenRespawns = 0;
int currentRun = -1;
bool lastJump = false;
bool runJumped = false;
double runElapsed = 0;
double runMaxSpeed = 0;

bool haveLastBall = false;
double lastBallX = 0, lastBallY = 0, lastBallZ = 0;

bool wasActive = false;
bool finishPending = false;
double finishUntil = 0;
double finishTime = 0;
double finishMaxSpeed = 0;
bool finishJumped = false;
string finishTrackKey = "";
string finishTrackName = "";
double finishAuthorTime = 0;

int publishedQuery = -1;
double nextPublishedTry = 0;

double lastSave = 0;

// UI.
UI::FooterButton@ footer;
UI::Window@ window;
int listView = 0;
UI::Button@ closeButton;
UI::Button@ filterButton;
bool incompleteOnly = false;
array<UI::Button@> pinButtons;
array<int> listedAchievements;

UI::Window@ pinnedHud;
UI::Text@ pinnedTitle;
UI::Text@ pinnedProgress;
int pinnedIndex = 0;

double nextListRefresh = 0;

void Main()
{
    BuildAchievements();
    Load();

    seenRestarts = Race::Restarts();
    seenRespawns = Race::Respawns();
    wasActive = Race::IsActive();
    currentRun = Race::RunId();
    lastSave = Host::Time();

    @footer = UI::AddFooterButton("achievements");
    BuildWindow();
    BuildPinnedHud();

    StartPublishedCheck();
    Log::Info("Achievement Tracker 0.1.0 loaded: local progress only; Steam sync is not available in the current host API");
}

void OnDisabled()
{
    Save();
}

void OnSettingsChanged()
{
    if (pinnedTitle !is null)
        pinnedTitle.size = PinnedHudSize;
    if (pinnedProgress !is null)
        pinnedProgress.size = PinnedHudSize * 0.88f;
}

void BuildAchievements()
{
    achievements = {
        Achievement("first-finish", "The Show Begins", "Beat your first track", true),
        Achievement("wet-ball", "One Wet Ball", "Fall in the water", false),
        Achievement("tower", "Great Heights", "Finish the Tower", true),
        Achievement("architect", "Architect", "Publish your first custom track", true),
        Achievement("author", "It's MY track now", "Beat the author time on a track", true),
        Achievement("air-hour", "Air Apparent", "Spend an hour total in the air", false, 3600),
        Achievement("miles", "I Would Roll 500 Miles", "Roll for 500 total miles", true, 500),
        Achievement("jumps", "Bouncy", "Jump 10,000 total times", true, 10000),
        Achievement("restarts", "Practice Makes Perfect", "Restart 1,000 times", true, 1000),
        Achievement("grounded", "Grounded", "Finish a track without jumping", true),
        Achievement("flat20", "20 Flat", "Finish a track with exact time 20.000", true),
        Achievement("pbs", "Take that!", "Beat your personal best 10 times", true, 10),
        Achievement("glacial", "Glacial Pace", "Finish a track without ever reaching 15mph", true),
        Achievement("fastball", "Fastball", "Reach 65mph", true),
        Achievement("air10", "Ahhhh!!!!", "Spend at least 10 seconds airborne", false, 10),
        Achievement("crowd-off", "Ahhhh.....", "Turn the crowd off", false)
    };
}

void Load()
{
    jumps = int(parseInt(Storage::Get("jumps", "0")));
    restartActions = int(parseInt(Storage::Get("restarts", "0")));
    distanceCm = parseFloat(Storage::Get("distance_cm", "0"));
    pbBeats = int(parseInt(Storage::Get("pb_beats", "0")));

    firstFinish = Storage::Get("first_finish", "0") == "1";
    towerFinish = Storage::Get("tower_finish", "0") == "1";
    architect = Storage::Get("architect", "0") == "1";
    beatAuthor = Storage::Get("beat_author", "0") == "1";
    grounded = Storage::Get("grounded", "0") == "1";
    flat20 = Storage::Get("flat20", "0") == "1";
    glacial = Storage::Get("glacial", "0") == "1";
    fastball = Storage::Get("fastball", "0") == "1";

    pinnedIndex = int(parseInt(Storage::Get("pinned", "0")));
    if (pinnedIndex < 0 || pinnedIndex >= int(achievements.length()))
        pinnedIndex = 0;
}

void Save()
{
    Storage::Set("jumps", "" + jumps);
    Storage::Set("restarts", "" + restartActions);
    Storage::Set("distance_cm", formatFloat(distanceCm, "", 0, 1));
    Storage::Set("pb_beats", "" + pbBeats);

    Storage::Set("first_finish", firstFinish ? "1" : "0");
    Storage::Set("tower_finish", towerFinish ? "1" : "0");
    Storage::Set("architect", architect ? "1" : "0");
    Storage::Set("beat_author", beatAuthor ? "1" : "0");
    Storage::Set("grounded", grounded ? "1" : "0");
    Storage::Set("flat20", flat20 ? "1" : "0");
    Storage::Set("glacial", glacial ? "1" : "0");
    Storage::Set("fastball", fastball ? "1" : "0");
    Storage::Set("pinned", "" + pinnedIndex);

    lastSave = Host::Time();
}

void BuildWindow()
{
    @window = UI::CreateWindow();
    window.SetScreenSize(0.68f, 0.82f);
    window.SetBackground(WINDOW_R, WINDOW_G, WINDOW_B, 0.97f);
    window.SetCardBackground(CARD_R, CARD_G, CARD_B, 1);
    window.SetBlocksClicks(true);
    window.zOrder = 460;
    window.visible = false;

    window.StartHeader();
    window.AddText("achievement tracker", 28);
    window.AddSpace(16);
    @filterButton = window.AddButton("all");
    Secondary(filterButton);
    window.AddSpace(0);
    @closeButton = window.AddButton("close");
    Secondary(closeButton);

    listView = window.StartView();
    window.SetScrolling(listView, true);
}

void BuildPinnedHud()
{
    @pinnedHud = UI::CreateWindow();
    pinnedHud.SetAnchor(0, 0);
    pinnedHud.SetPivot(0, 0);
    pinnedHud.SetOffset(36, 150);
    pinnedHud.SetPadding(14, 10);
    pinnedHud.SetBackground(WINDOW_R, WINDOW_G, WINDOW_B, 0.82f);
    @pinnedTitle = pinnedHud.AddText("", PinnedHudSize);
    pinnedTitle.SetColor(1, 1, 1, 1);
    pinnedHud.NewRow();
    @pinnedProgress = pinnedHud.AddText("", PinnedHudSize * 0.88f);
    pinnedProgress.SetColor(GREEN_R, GREEN_G, GREEN_B, 1);
    pinnedHud.movable = true;
    pinnedHud.visible = false;
}

UI::Text@ Muted(UI::Text@ t)
{
    t.SetColor(MUTED_R, MUTED_G, MUTED_B, 1);
    return t;
}

void Secondary(UI::Button@ b)
{
    b.SetBackground(BUTTON_R, BUTTON_G, BUTTON_B, 1);
}

void Primary(UI::Button@ b)
{
    b.SetBackground(PRIMARY_R, PRIMARY_G, PRIMARY_B, 1);
}

bool LocalComplete(Achievement@ a)
{
    if (a.id == "first-finish") return firstFinish;
    if (a.id == "tower") return towerFinish;
    if (a.id == "architect") return architect;
    if (a.id == "author") return beatAuthor;
    if (a.id == "miles") return distanceCm / CM_PER_MILE >= 500;
    if (a.id == "jumps") return jumps >= 10000;
    if (a.id == "restarts") return restartActions >= 1000;
    if (a.id == "grounded") return grounded;
    if (a.id == "flat20") return flat20;
    if (a.id == "pbs") return pbBeats >= 10;
    if (a.id == "glacial") return glacial;
    if (a.id == "fastball") return fastball;
    return false;
}

double MinD(double a, double b)
{
    return a < b ? a : b;
}

double LocalValue(Achievement@ a)
{
    if (a.id == "miles") return distanceCm / CM_PER_MILE;
    if (a.id == "jumps") return jumps;
    if (a.id == "restarts") return restartActions;
    if (a.id == "pbs") return pbBeats;
    return LocalComplete(a) ? 1 : 0;
}

string ProgressText(Achievement@ a)
{
    if (!a.trackable)
        return "Steam sync needed";

    if (a.id == "miles")
        return formatFloat(MinD(LocalValue(a), a.goal), "", 0, 1) + " / 500 mi";

    if (a.goal > 1)
        return int(MinD(LocalValue(a), a.goal)) + " / " + int(a.goal);

    return LocalComplete(a) ? "local evidence: complete" : "not seen locally yet";
}

int TrackableCount()
{
    int n = 0;
    for (uint i = 0; i < achievements.length(); i++)
        if (achievements[i].trackable)
            n++;
    return n;
}

int LocalCompleteCount()
{
    int n = 0;
    for (uint i = 0; i < achievements.length(); i++)
        if (achievements[i].trackable && LocalComplete(achievements[i]))
            n++;
    return n;
}

void BuildList()
{
    window.ClearView(listView);
    window.ShowView(listView);
    pinButtons.resize(0);
    listedAchievements.resize(0);

    window.StartCard();
    UI::Text@ heading = window.AddText("16 Steam achievements", 24);
    heading.SetColor(1, 1, 1, 1);
    window.NewRow();
    UI::Text@ local = window.AddText("local evidence  " + LocalCompleteCount() + " / " + TrackableCount() + " trackable", 18);
    local.SetColor(GREEN_R, GREEN_G, GREEN_B, 1);
    window.NewRow();
    Muted(window.AddText("Steam unlock state is not exposed by Plugin Manager 0.23.6, so this page never guesses unsupported progress.", 14));
    window.EndCard();

    for (uint i = 0; i < achievements.length(); i++)
    {
        Achievement@ a = achievements[i];
        if (incompleteOnly && a.trackable && LocalComplete(a))
            continue;

        listedAchievements.insertLast(int(i));

        window.StartCard();

        UI::Text@ name = window.AddText(a.name, 20);
        name.SetWidth(330);
        if (a.trackable && LocalComplete(a))
            name.SetColor(GREEN_R, GREEN_G, GREEN_B, 1);

        UI::Text@ progress = window.AddText(ProgressText(a), 16);
        progress.SetWidth(230);
        if (!a.trackable)
            progress.SetColor(WARN_R, WARN_G, WARN_B, 1);
        else if (LocalComplete(a))
            progress.SetColor(GREEN_R, GREEN_G, GREEN_B, 1);

        window.AddSpace(0);
        UI::Button@ pin = window.AddButton(int(i) == pinnedIndex ? "pinned" : "pin");
        if (int(i) == pinnedIndex)
            Primary(pin);
        else
            Secondary(pin);
        pinButtons.insertLast(pin);

        window.NewRow();
        Muted(window.AddText(a.description, 14));
        window.EndCard();
    }

    window.ShowView(listView);
    nextListRefresh = Host::Time() + 0.5;
}

void OpenWindow(bool on)
{
    window.visible = on;
    if (on)
        BuildList();
}

void UpdateWindow()
{
    if (footer.Clicked())
        OpenWindow(!window.visible);

    if (!window.visible)
        return;

    if (closeButton.Clicked() || Input::Pressed(Input::Escape))
    {
        OpenWindow(false);
        return;
    }

    if (filterButton.Clicked())
    {
        incompleteOnly = !incompleteOnly;
        filterButton.label = incompleteOnly ? "incomplete" : "all";
        BuildList();
        return;
    }

    for (uint i = 0; i < pinButtons.length(); i++)
        if (pinButtons[i].Clicked())
        {
            pinnedIndex = listedAchievements[i];
            Save();
            BuildList();
            return;
        }

    if (Host::Time() >= nextListRefresh)
        BuildList();
}

void UpdatePinnedHud()
{
    bool visible = ShowPinnedHud && Race::OnTrack() && pinnedIndex >= 0 && pinnedIndex < int(achievements.length());
    pinnedHud.visible = visible;

    if (!visible)
        return;

    Achievement@ a = achievements[pinnedIndex];
    pinnedTitle.text = a.name;
    pinnedProgress.text = ProgressText(a);

    if (!a.trackable)
        pinnedProgress.SetColor(WARN_R, WARN_G, WARN_B, 1);
    else
        pinnedProgress.SetColor(GREEN_R, GREEN_G, GREEN_B, 1);
}

void StartPublishedCheck()
{
    if (architect || publishedQuery >= 0 || Host::Time() < nextPublishedTry)
        return;

    publishedQuery = Workshop::FindList("published");
    if (publishedQuery < 0)
        nextPublishedTry = Host::Time() + 10;
}

void UpdatePublishedCheck()
{
    if (architect)
        return;

    if (publishedQuery < 0)
    {
        StartPublishedCheck();
        return;
    }

    string state = Workshop::State(publishedQuery);
    if (state == "done")
    {
        if (Workshop::Count(publishedQuery) > 0)
        {
            architect = true;
            Save();
        }
        Workshop::Forget(publishedQuery);
        publishedQuery = -1;
        nextPublishedTry = Host::Time() + 60;
    }
    else if (state.findFirst("error:") == 0 || state == "")
    {
        if (state != "")
            Log::Warn("achievement tracker: published-map check failed: " + state);
        publishedQuery = -1;
        nextPublishedTry = Host::Time() + 30;
    }
}

void BeginRun(int run)
{
    currentRun = run;
    runElapsed = 0;
    runMaxSpeed = 0;
    runJumped = false;
    lastJump = false;
    haveLastBall = false;
}

void UpdateCounters()
{
    int restarts = Race::Restarts();
    int respawns = Race::Respawns();

    if (restarts > seenRestarts)
        restartActions += restarts - seenRestarts;
    if (respawns > seenRespawns)
        restartActions += respawns - seenRespawns;

    seenRestarts = restarts;
    seenRespawns = respawns;
}

void UpdateRun(float dt)
{
    bool active = Race::IsActive();
    int run = Race::RunId();

    if (active && run >= 0 && run != currentRun)
        BeginRun(run);

    if (!active || Race::IsPaused())
    {
        haveLastBall = false;
        lastJump = false;
        return;
    }

    if (dt > 0 && dt < 0.25f)
        runElapsed += dt;

    double xInput, yInput;
    bool jump;
    if (Race::GetInput(xInput, yInput, jump))
    {
        if (jump)
            runJumped = true;

        if (jump && !lastJump)
            jumps++;

        lastJump = jump;
    }

    double x, y, z;
    if (!Race::BallPosition(x, y, z))
    {
        haveLastBall = false;
        return;
    }

    if (haveLastBall && dt > 0.001f && dt < 0.25f)
    {
        double dx = x - lastBallX;
        double dy = y - lastBallY;
        double dz = z - lastBallZ;
        double moved = Math::sqrt(dx * dx + dy * dy + dz * dz);

        // Ignore map loads, teleports and other discontinuities. At ordinary
        // Ballest speeds a real frame-to-frame move is far below this.
        double plausible = 10000.0 * dt + 500.0;
        if (moved <= plausible)
        {
            distanceCm += moved;
            double mph = (moved / dt) / 44.704;
            if (mph > runMaxSpeed)
                runMaxSpeed = mph;
            if (mph >= 65.0 && !fastball)
            {
                fastball = true;
                Save();
            }
        }
    }

    lastBallX = x;
    lastBallY = y;
    lastBallZ = z;
    haveLastBall = true;
}

string SafeKey(const string &in raw)
{
    string result = "";
    for (uint i = 0; i < raw.length(); i++)
    {
        if (raw[i] == 61)
            result += "%3D";
        else
            result += raw.substr(i, 1);
    }
    return result;
}

bool LooksLikeTower(const string &in key, const string &in name)
{
    string k = Lower(key);
    string n = Lower(name);
    return k.findFirst("tower") >= 0 || n.findFirst("tower") >= 0;
}

string Lower(const string &in text)
{
    string result = text;
    for (uint i = 0; i < result.length(); i++)
        if (result[i] >= 65 && result[i] <= 90)
            result[i] = result[i] + 32;
    return result;
}

void WatchFinish()
{
    bool active = Race::IsActive();
    bool complete = Race::IsComplete();

    if (wasActive && !active && complete && !finishPending)
    {
        finishPending = true;
        finishUntil = Host::Time() + FINISH_WAIT;
        finishTime = runElapsed;
        finishMaxSpeed = runMaxSpeed;
        finishJumped = runJumped;
        finishTrackKey = Race::TrackKey();
        finishTrackName = Race::TrackName();
        finishAuthorTime = Race::AuthorTime();
    }

    if (finishPending)
    {
        if (Race::RunId() < 0)
        {
            RecordFinish();
            finishPending = false;
        }
        else if (Host::Time() > finishUntil)
        {
            finishPending = false;
        }
    }

    wasActive = active;
}

void RecordFinish()
{
    firstFinish = true;

    if (LooksLikeTower(finishTrackKey, finishTrackName))
        towerFinish = true;

    if (finishAuthorTime > 0 && finishTime > 0 && finishTime < finishAuthorTime)
        beatAuthor = true;

    if (!finishJumped)
        grounded = true;

    int millis = int(finishTime * 1000.0 + 0.5);
    if (millis == 20000)
        flat20 = true;

    if (finishMaxSpeed > 0 && finishMaxSpeed < 15.0)
        glacial = true;

    if (finishTrackKey != "" && finishTime > 0)
    {
        string key = "best:" + SafeKey(finishTrackKey);
        double oldBest = parseFloat(Storage::Get(key, "0"));

        if (oldBest > 0 && finishTime + 0.001 < oldBest)
            pbBeats++;

        if (oldBest <= 0 || finishTime < oldBest)
            Storage::Set(key, formatFloat(finishTime, "", 0, 3));
    }

    Save();
}

void Update(float dt)
{
    UpdateCounters();
    UpdateRun(dt);
    WatchFinish();
    UpdatePublishedCheck();
    UpdateWindow();
    UpdatePinnedHud();

    if (Host::Time() - lastSave >= SAVE_EVERY)
        Save();
}
