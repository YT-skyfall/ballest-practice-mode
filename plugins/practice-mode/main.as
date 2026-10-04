// Practice Mode - AnythingGoes Plugin Manager edition
//
// Source-only port of Ballest Practice Mode. It uses only the public Plugin
// Manager API. Race::LoadBall always enables the host's fail-closed practice
// protection before moving the ball.

[Setting name="Full restart key" description="Match Ballest's full-restart binding so Practice Mode can distinguish a full restart from a normal restart. Examples: Backspace, PadView, PadMenu, PadA, PadB, PadX, PadY, PadLB, PadRB, PadLT, PadRT, PadUp, PadDown, PadLeft, PadRight."]
string FullRestartKey = "Backspace";

[Setting name="Show practice HUD" description="Show the Practice Mode state and attempt count while practicing."]
bool ShowHud = true;

UI::FooterButton@ footerButton;
UI::Panel@ controlPanel;
UI::FooterButton@ setPointButton;
UI::FooterButton@ restartButton;
UI::FooterButton@ clearPointButton;

UI::Window@ hudWindow;
UI::Text@ hudTitle;
UI::Text@ hudAttempts;

string savedState = "";
string currentTrack = "";
string statusMessage = "enter a track to begin";

bool practiceEnabled = false;

bool pendingLoad = false;
bool pendingStartOnly = false;
double pendingTryAt = 0;
double pendingExpireAt = 0;

double fullRestartPressedAt = -100;

int attempts = 0;
int seenRestarts = 0;
int seenRespawns = 0;
int seenFalls = 0;

double nextPanelRefresh = 0;

void Main()
{
    @footerButton = UI::AddFooterButton("practice mode");

    @controlPanel = UI::CreatePanel();
    controlPanel.title = "practice mode";
    @setPointButton = controlPanel.AddButton("set practice point");
    @restartButton = controlPanel.AddButton("restart practice");
    @clearPointButton = controlPanel.AddButton("clear practice point");

    @hudWindow = UI::CreateWindow();
    hudWindow.SetAnchor(0, 0);
    hudWindow.SetPivot(0, 0);
    hudWindow.SetOffset(36, 150);
    @hudTitle = hudWindow.AddText("PRACTICE MODE", 18);
    hudTitle.SetColor(0.35f, 1.0f, 0.35f, 1.0f);
    hudWindow.NewRow();
    @hudAttempts = hudWindow.AddText("attempts: 0", 14);
    hudWindow.visible = false;

    seenRestarts = Race::Restarts();
    seenRespawns = Race::Respawns();
    seenFalls = Race::Falls();

    OnSettingsChanged();
    RefreshPanel();

    Log::Info("Practice Mode 0.1.0 loaded");
}

void OnSettingsChanged()
{
    if (KeyCode(FullRestartKey) == 0)
        Log::Warn("Full restart key '" + FullRestartKey + "' is not recognized");
}

void Update(float dt)
{
    if (footerButton.Clicked())
    {
        controlPanel.visible = !controlPanel.visible;
        RefreshPanel();
    }

    TrackChanged();
    HandleButtons();
    WatchFullRestartKey();
    WatchGameRestarts();
    ProcessPendingAction();
    RefreshHud();

    if (controlPanel.visible && Host::Time() >= nextPanelRefresh)
    {
        nextPanelRefresh = Host::Time() + 0.25;
        RefreshPanel();
    }
}

void TrackChanged()
{
    string key = Race::TrackKey();

    if (key == "")
        return;

    if (currentTrack == "")
    {
        currentTrack = key;
        statusMessage = "ready to set a practice point";
        return;
    }

    if (key == currentTrack)
        return;

    currentTrack = key;
    savedState = "";
    practiceEnabled = false;
    attempts = 0;
    CancelPending();
    statusMessage = "new track: set a practice point";
    RefreshPanel();
}

void HandleButtons()
{
    if (setPointButton.Clicked())
        SetPracticePoint();

    if (restartButton.Clicked())
        RestartPractice();

    if (clearPointButton.Clicked())
        ClearPracticePoint();
}

void SetPracticePoint()
{
    if (!Race::OnTrack() || !Race::IsActive())
    {
        statusMessage = "start the race before setting a point";
        RefreshPanel();
        return;
    }

    string state = Race::SaveBall();
    if (state == "")
    {
        statusMessage = "no ball available to save";
        RefreshPanel();
        return;
    }

    Race::StartPractice();
    if (!Race::IsPractice())
    {
        statusMessage = "practice safety could not be verified";
        Log::Warn("Practice Mode: host refused to enable practice protection");
        RefreshPanel();
        return;
    }

    savedState = state;
    practiceEnabled = true;
    attempts = 0;
    CancelPending();

    setPointButton.label = "replace practice point";
    statusMessage = "practice point set";
    RefreshPanel();
}

void RestartPractice()
{
    if (savedState == "")
    {
        statusMessage = "set a practice point first";
        RefreshPanel();
        return;
    }

    if (!Race::OnTrack())
    {
        statusMessage = "open the saved track first";
        RefreshPanel();
        return;
    }

    if (Race::LoadBall(savedState, true))
    {
        practiceEnabled = true;
        attempts++;
        statusMessage = "restarted from practice point";
    }
    else
    {
        statusMessage = "ball is not ready yet";
    }

    RefreshPanel();
}

void ClearPracticePoint()
{
    savedState = "";
    practiceEnabled = false;
    attempts = 0;
    CancelPending();

    setPointButton.label = "set practice point";

    if (Race::IsPractice())
        statusMessage = "point cleared; full restart for a normal run";
    else
        statusMessage = "practice point cleared";

    RefreshPanel();
}

void WatchFullRestartKey()
{
    int code = KeyCode(FullRestartKey);
    if (code > 0 && Input::Pressed(Input::Key(code)))
        fullRestartPressedAt = Host::Time();
}

void WatchGameRestarts()
{
    int nowRestarts = Race::Restarts();
    if (nowRestarts > seenRestarts)
    {
        int added = nowRestarts - seenRestarts;
        seenRestarts = nowRestarts;

        if (practiceEnabled && savedState != "")
        {
            bool fullRestart = Host::Time() - fullRestartPressedAt < 2.5;

            if (fullRestart)
            {
                SchedulePracticeStart();
                statusMessage = "full restart: original track start";
            }
            else
            {
                SchedulePracticeLoad(added);
                statusMessage = "normal restart: returning to practice point";
            }
        }
    }
    else
    {
        seenRestarts = nowRestarts;
    }

    int nowRespawns = Race::Respawns();
    if (nowRespawns > seenRespawns)
    {
        int added = nowRespawns - seenRespawns;
        seenRespawns = nowRespawns;

        if (practiceEnabled && savedState != "")
        {
            SchedulePracticeLoad(added);
            statusMessage = "respawn: returning to practice point";
        }
    }
    else
    {
        seenRespawns = nowRespawns;
    }

    int nowFalls = Race::Falls();
    if (nowFalls > seenFalls)
    {
        int added = nowFalls - seenFalls;
        seenFalls = nowFalls;

        if (practiceEnabled && savedState != "")
        {
            SchedulePracticeLoad(added);
            statusMessage = "fall: returning to practice point";
        }
    }
    else
    {
        seenFalls = nowFalls;
    }
}

void SchedulePracticeLoad(int addedAttempts)
{
    pendingLoad = true;
    pendingStartOnly = false;
    pendingTryAt = Host::Time() + 0.08;
    pendingExpireAt = Host::Time() + 3.0;
    attempts += addedAttempts;
}

void SchedulePracticeStart()
{
    pendingLoad = true;
    pendingStartOnly = true;
    pendingTryAt = Host::Time() + 0.08;
    pendingExpireAt = Host::Time() + 3.0;
}

void ProcessPendingAction()
{
    if (!pendingLoad || Host::Time() < pendingTryAt)
        return;

    if (Host::Time() > pendingExpireAt)
    {
        Log::Warn("Practice Mode: timed out waiting for the new run");
        statusMessage = "could not restore practice after restart";
        CancelPending();
        RefreshPanel();
        return;
    }

    if (!Race::OnTrack() || !Race::IsActive())
    {
        pendingTryAt = Host::Time() + 0.05;
        return;
    }

    if (pendingStartOnly)
    {
        Race::StartPractice();

        if (Race::IsPractice())
        {
            statusMessage = "practice active from original start";
            CancelPending();
            RefreshPanel();
            return;
        }
    }
    else if (savedState != "" && Race::LoadBall(savedState, true))
    {
        statusMessage = "practice point restored";
        CancelPending();
        RefreshPanel();
        return;
    }

    pendingTryAt = Host::Time() + 0.05;
}

void CancelPending()
{
    pendingLoad = false;
    pendingStartOnly = false;
    pendingTryAt = 0;
    pendingExpireAt = 0;
}

void RefreshHud()
{
    bool active = Race::OnTrack() && ShowHud && (practiceEnabled || Race::IsPractice());

    hudWindow.visible = active;

    if (!active)
        return;

    hudTitle.text = Race::IsPractice() ? "PRACTICE MODE" : "PRACTICE MODE - READY";
    hudAttempts.text = "attempts: " + attempts;
}

void RefreshPanel()
{
    controlPanel.Clear();

    if (!Race::OnTrack())
    {
        controlPanel.AddLine("open a track to use Practice Mode");
    }
    else
    {
        controlPanel.AddLine(savedState == "" ? "practice point: not set" : "practice point: set");
        controlPanel.AddLine("attempts: " + attempts);
        controlPanel.AddLine("leaderboard protection: " + (Race::IsPractice() ? "active" : (practiceEnabled ? "ready" : "normal run")));
        controlPanel.AddLine("full restart key: " + FullRestartKey);
    }

    controlPanel.AddLine(statusMessage);
}

int KeyCode(const string &in raw)
{
    string name = Upper(Trim(raw));

    if (name.length() == 1)
    {
        uint8 c = name[0];

        if ((c >= 65 && c <= 90) || (c >= 48 && c <= 57))
            return c;

        return 0;
    }

    if (name.length() <= 3 && name.length() >= 2 && name[0] == 70)
    {
        int n = int(parseInt(name.substr(1)));

        if (n >= 1 && n <= 12)
            return 0x6F + n;
    }

    array<string> names = {
        "SPACE", "ENTER", "TAB", "SHIFT", "CTRL", "ALT",
        "LEFT", "UP", "RIGHT", "DOWN",
        "MOUSELEFT", "MOUSERIGHT", "MOUSEMIDDLE",
        "BACKSPACE", "DELETE",
        "PADA", "PADB", "PADX", "PADY",
        "PADLB", "PADRB", "PADLT", "PADRT",
        "PADL3", "PADR3", "PADVIEW", "PADMENU",
        "PADUP", "PADDOWN", "PADLEFT", "PADRIGHT",
        "PADSTICKUP", "PADSTICKDOWN", "PADSTICKLEFT", "PADSTICKRIGHT"
    };

    array<int> codes = {
        0x20, 0x0D, 0x09, 0x10, 0x11, 0x12,
        0x25, 0x26, 0x27, 0x28,
        0x01, 0x02, 0x04,
        0x08, 0x2E,
        0x100, 0x101, 0x102, 0x103,
        0x104, 0x105, 0x106, 0x107,
        0x108, 0x109, 0x10A, 0x10B,
        0x10C, 0x10D, 0x10E, 0x10F,
        0x110, 0x111, 0x112, 0x113
    };

    int i = names.find(name);
    return i >= 0 ? codes[i] : 0;
}

string Trim(const string &in s)
{
    int first = s.findFirstNotOf(" \t");

    if (first < 0)
        return "";

    int last = s.findLastNotOf(" \t");
    return s.substr(first, last - first + 1);
}

string Upper(const string &in s)
{
    string r = s;

    for (uint i = 0; i < r.length(); i++)
    {
        if (r[i] >= 97 && r[i] <= 122)
            r[i] = uint8(r[i] - 32);
    }

    return r;
}
