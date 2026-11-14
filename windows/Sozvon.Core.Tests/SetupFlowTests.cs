using Sozvon.Core.Engine;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Tests;

public sealed class SetupFlowTests : TempFolders
{
    private const int Model = SetupFlow.ModelStep;

    [Fact]
    public void OnlyAReadyEngineCountsAsInstalled()
    {
        Assert.True(SetupFlow.Installed(EngineStateKind.Ready));
        // A stopped first install leaves a venv without a model and without .venv-lock: not installed.
        Assert.False(SetupFlow.Installed(EngineStateKind.NeedsUpdate));
        Assert.False(SetupFlow.Installed(EngineStateKind.ModelMissing));
        Assert.False(SetupFlow.Installed(EngineStateKind.NotInstalled));
    }

    [Fact]
    public void AStoppedFirstInstallIsNotInstalled()
    {
        var layout = new EngineLayout(Data, Calls);
        // setup.ps1 copied the engine with its uv.lock and made the venv, then the download was stopped.
        WriteText(Path.Combine(Data, "uv.lock"), "lock");
        WriteText(layout.Python, "x");
        Assert.False(SetupFlow.Installed(EngineState.Evaluate(layout, WhisperModel.Turbo)));
        // An .installed left from an earlier version, the new install stopped before its .venv-lock.
        MarkInstalled();
        Assert.Equal(EngineStateKind.NeedsUpdate, EngineState.Evaluate(layout, WhisperModel.Turbo));
        Assert.False(SetupFlow.Installed(EngineState.Evaluate(layout, WhisperModel.Turbo)));
        WriteText(Path.Combine(Data, ".venv-lock"), EngineState.LockHash("lock"u8.ToArray()));
        Assert.False(SetupFlow.Installed(EngineState.Evaluate(layout, WhisperModel.Turbo)));
        WriteText(Path.Combine(Data, "models", "whisper-large-v3-turbo", ".complete"), "");
        Assert.True(SetupFlow.Installed(EngineState.Evaluate(layout, WhisperModel.Turbo)));
    }

    [Fact]
    public void ResumeStep()
    {
        Assert.Equal(0, SetupFlow.Resume(null, EngineStateKind.NotInstalled));
        Assert.Equal(2, SetupFlow.Resume(2, EngineStateKind.NotInstalled));
        Assert.Equal(Model, SetupFlow.Resume(Model, EngineStateKind.NotInstalled));
        Assert.Equal(Model + 2, SetupFlow.Resume(Model + 2, EngineStateKind.Ready));
        // Closed during the download: back to the model choice, the download continues from there.
        Assert.Equal(Model, SetupFlow.Resume(Model + 1, EngineStateKind.NeedsUpdate));
        Assert.Equal(Model, SetupFlow.Resume(Model + 2, EngineStateKind.ModelMissing));
        Assert.Equal(Model, SetupFlow.Resume(Model + 3, EngineStateKind.NotInstalled));
        Assert.Equal(0, SetupFlow.Resume(-1, EngineStateKind.Ready));
    }

    [Fact]
    public void WhereSetupOpens()
    {
        var unfinished = new SetupProgress(Model + 1, false);
        Assert.True(SetupFlow.OpensAtStart(unfinished, EngineStateKind.Ready));
        Assert.Equal(Model + 1, SetupFlow.OpenAt(unfinished, EngineStateKind.Ready));
        Assert.Equal(Model, SetupFlow.OpenAt(unfinished, EngineStateKind.NotInstalled));

        var done = new SetupProgress(null, true);
        Assert.False(SetupFlow.OpensAtStart(done, EngineStateKind.Ready));
        Assert.False(SetupFlow.OpensAtStart(done, EngineStateKind.NeedsUpdate));
        Assert.True(SetupFlow.OpensAtStart(done, EngineStateKind.ModelMissing));
        // After setup "Finish Setup…" is the model choice and the download.
        Assert.Equal(Model, SetupFlow.OpenAt(done, EngineStateKind.ModelMissing));

        // From before the progress file: set up when the engine works.
        Assert.True(SetupFlow.IsDone(SetupProgress.None, EngineStateKind.Ready));
        Assert.False(SetupFlow.IsDone(SetupProgress.None, EngineStateKind.NotInstalled));
        Assert.Equal(0, SetupFlow.OpenAt(SetupProgress.None, EngineStateKind.NotInstalled));
    }

    [Fact]
    public void TheDownloadCannotBeSkipped()
    {
        Assert.Equal(new InstallFooter(InstallAction.Continue, false), SetupFlow.Footer(InstallPhase.Running));
        Assert.Equal(new InstallFooter(InstallAction.Continue, true), SetupFlow.Footer(InstallPhase.Done));
        Assert.Equal(new InstallFooter(InstallAction.Retry, true), SetupFlow.Footer(InstallPhase.Failed));
        Assert.Equal(new InstallFooter(InstallAction.ContinueInstall, true), SetupFlow.Footer(InstallPhase.Stopped));
    }

    [Fact]
    public void SettingsBanner()
    {
        Assert.Equal(SetupBanner.None, SetupFlow.Banner(EngineStateKind.Ready, installing: false));
        Assert.Equal(SetupBanner.None, SetupFlow.Banner(EngineStateKind.NeedsUpdate, installing: false));
        Assert.Equal(SetupBanner.Incomplete, SetupFlow.Banner(EngineStateKind.ModelMissing, installing: false));
        Assert.Equal(SetupBanner.Incomplete, SetupFlow.Banner(EngineStateKind.NotInstalled, installing: false));
        Assert.Equal(SetupBanner.Installing, SetupFlow.Banner(EngineStateKind.ModelMissing, installing: true));
        Assert.Equal(SetupBanner.Installing, SetupFlow.Banner(EngineStateKind.NeedsUpdate, installing: true));
        Assert.Equal(SetupBanner.None, SetupFlow.Banner(EngineStateKind.Ready, installing: true));
        Assert.Equal(SetupProblem.ModelMissing, SetupFlow.Problem(EngineStateKind.ModelMissing));
        Assert.Equal(SetupProblem.EngineMissing, SetupFlow.Problem(EngineStateKind.NotInstalled));
        Assert.Null(SetupFlow.Problem(EngineStateKind.NeedsUpdate));
    }

    [Fact]
    public void ProgressIsKeptInTheDataFolder()
    {
        Assert.Equal(SetupProgress.None, SetupProgress.Load(Data));
        SetupProgress.SaveStep(Data, Model + 1);
        Assert.Equal(new SetupProgress(Model + 1, false), SetupProgress.Load(Data));
        SetupProgress.SaveDone(Data);
        Assert.Equal(new SetupProgress(null, true), SetupProgress.Load(Data));
        WriteText(SetupProgress.PathIn(Data), "{ broken");
        Assert.Equal(SetupProgress.None, SetupProgress.Load(Data));
    }

    [Fact]
    public void TheLogTellsARunningInstallAndItsStep()
    {
        var log = SetupLog.PathIn(Data);
        Assert.False(SetupLog.IsBeingWritten(log));
        using (var writer = new StreamWriter(new FileStream(log, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) { AutoFlush = true })
        {
            writer.WriteLine("==> Скачиваю Python");
            writer.WriteLine("python.zip: 11 MB");
            writer.WriteLine("==> Скачиваю модель Whisper Turbo (1.6 ГБ)");
            writer.WriteLine("model.bin: 12%");
            Assert.True(SetupLog.IsBeingWritten(log));
            Assert.Equal("Скачиваю модель Whisper Turbo (1.6 ГБ)", SetupLog.Phase(SetupLog.Tail(log)));
        }
        Assert.False(SetupLog.IsBeingWritten(log));
        Assert.Equal("", SetupLog.Phase(["no steps"]));
    }
}
