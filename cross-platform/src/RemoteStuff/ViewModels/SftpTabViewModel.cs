using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Renci.SshNet;
using Renci.SshNet.Sftp;
using RemoteStuff.Models;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

/// <summary>One row in the SFTP browser.</summary>
public sealed class SftpEntryViewModel
{
    public required string Name { get; init; }
    public required string FullPath { get; init; }
    public bool IsDirectory { get; init; }
    public bool IsParent { get; init; }
    public long Size { get; init; }
    public DateTime Modified { get; init; }
    public string Permissions { get; init; } = "";

    public string Glyph => IsParent ? "↩" : IsDirectory ? "📁" : "📄";
    public string SizeText => IsDirectory ? "" : HumanSize(Size);
    public string ModifiedText => IsParent ? "" : Modified.ToString("yyyy-MM-dd HH:mm");

    private static string HumanSize(long bytes)
    {
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        double v = bytes; var u = 0;
        while (v >= 1024 && u < units.Length - 1) { v /= 1024; u++; }
        return u == 0 ? $"{bytes} B" : $"{v:0.#} {units[u]}";
    }
}

/// <summary>One clickable segment of the current-path breadcrumb.</summary>
public sealed class SftpCrumb
{
    public required string Name { get; init; }
    public required string FullPath { get; init; }
}

/// <summary>Payload carried on the clipboard/drag data when an SFTP row is dragged,
/// so a Finder drop target can ask the originating tab to download the item.</summary>
public sealed record SftpDragData(SftpTabViewModel Source, SftpEntryViewModel Entry);

/// <summary>An SFTP file-browser tab backed by SSH.NET.</summary>
public sealed partial class SftpTabViewModel : TabViewModel
{
    private readonly SshProfile _profile;
    private string? _password;
    private SftpClient? _client;
    private readonly Action<string>? _passwordSaver;

    public override string Glyph => "📁";

    public override (string Host, int Port)? ConnectionEndpoint =>
        _profile is { IsLocal: false, Host: { Length: > 0 } h }
            ? (h, int.TryParse(_profile.Port, out var pt) && pt > 0 ? pt : 22)
            : null;

    public override RemoteStuff.Services.TabSnapshot? CreateSnapshot()
    {
        if (_profile.IsLocal) return null;
        return new RemoteStuff.Services.TabSnapshot
        {
            Kind = "sftp",
            ProfileId = _profile.Id,
            Title = Title,
            Host = _profile.Host,
            Port = int.TryParse(_profile.Port, out var pt) ? pt : 22,
            Username = _profile.Username,
            Path = CurrentPath
        };
    }

    public ObservableCollection<SftpEntryViewModel> Entries { get; } = new();

    /// <summary>Clickable path segments for the current directory.</summary>
    public ObservableCollection<SftpCrumb> Crumbs { get; } = new();

    [ObservableProperty] private string _currentPath = ".";
    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private string _statusText = "Connecting…";
    [ObservableProperty] private bool _isConnected;
    [ObservableProperty] private SftpEntryViewModel? _selectedEntry;

    /// <summary>Shown when the connection isn't up, so the user can supply a
    /// password / passphrase and retry (e.g. after "permission denied").</summary>
    [ObservableProperty] private bool _showReconnect;

    /// <summary>Password / passphrase typed into the reconnect bar.</summary>
    [ObservableProperty] private string _reconnectPassword = "";

    /// <summary>When ticked, a successful reconnect saves the typed password to the profile.</summary>
    [ObservableProperty] private bool _savePassword = true;

    /// <summary>Hidden for ad-hoc tabs that have no saved profile to store a password on.</summary>
    public bool CanSavePassword => _passwordSaver is not null;

    /// <summary>The editable path box (lets the user jump to an arbitrary directory).</summary>
    [ObservableProperty] private string _pathInput = "";

    /// <summary>Raised to open a remote text file in an editor tab: (name, content, saver).</summary>
    public event Action<string, string, Func<string, Task>>? EditRequested;

    /// <summary>Raised to prompt the user for a name: (title, current) → entered text or null.</summary>
    public event Func<string, string, Task<string?>>? NameRequested;

    public SftpTabViewModel(SshProfile profile, string? password, Action<string>? passwordSaver = null)
    {
        _profile = profile;
        _password = password;
        _passwordSaver = passwordSaver;
        Title = "SFTP · " + profile.Name;
        _ = ConnectAsync();
    }

    /// <summary>Retry the connection using the password typed in the reconnect bar.</summary>
    [RelayCommand]
    private async Task Reconnect()
    {
        if (!string.IsNullOrEmpty(ReconnectPassword))
            _password = ReconnectPassword;
        await ConnectAsync();
    }

    // ---- FUSE mount (sshfs) ----

    private readonly SftpMounter _mounter = new();

    /// <summary>True once the remote home is mounted locally as a drive/folder.</summary>
    [ObservableProperty] private bool _isMounted;

    /// <summary>True while a mount/unmount is in progress.</summary>
    [ObservableProperty] private bool _isMountBusy;

    /// <summary>Status/error text for the mount action.</summary>
    [ObservableProperty] private string _mountStatus = "";

    /// <summary>Only profile-backed (non-local) tabs can be mounted.</summary>
    public bool CanMount => !_profile.IsLocal;

    /// <summary>Shown when sshfs isn't installed, so we can offer install guidance.</summary>
    public bool MountHelperMissing => !SftpMounter.HelperInstalled;

    /// <summary>Local path the remote is mounted at (empty when unmounted).</summary>
    public string MountPointPath => _mounter.MountPoint ?? "";

    /// <summary>Mount or unmount the remote home directory as a local drive.</summary>
    [RelayCommand]
    private async Task ToggleMount()
    {
        if (IsMountBusy) return;
        if (IsMounted) { await UnmountDrive(); return; }
        await MountDrive();
    }

    private async Task MountDrive()
    {
        if (!SftpMounter.HelperInstalled)
        {
            MountStatus = "sshfs isn't installed. On macOS: install macFUSE + sshfs (or fuse-t + sshfs) " +
                          "via Homebrew (brew install sshfs). On Linux: install the sshfs package.";
            OnPropertyChanged(nameof(MountHelperMissing));
            return;
        }

        IsMountBusy = true;
        MountStatus = "Mounting…";
        try
        {
            var (ok, message) = await _mounter.MountAsync(_profile, _password);
            if (ok)
            {
                IsMounted = true;
                MountStatus = "Mounted at " + message;
                OnPropertyChanged(nameof(MountPointPath));
                _mounter.Reveal();
            }
            else
            {
                IsMounted = false;
                MountStatus = message;
            }
        }
        catch (Exception ex) { MountStatus = "Mount failed: " + ex.Message; }
        finally { IsMountBusy = false; }
    }

    private async Task UnmountDrive()
    {
        IsMountBusy = true;
        MountStatus = "Unmounting…";
        try
        {
            await _mounter.UnmountAsync();
            IsMounted = false;
            MountStatus = "Unmounted";
            OnPropertyChanged(nameof(MountPointPath));
        }
        catch (Exception ex) { MountStatus = "Unmount failed: " + ex.Message; }
        finally { IsMountBusy = false; }
    }

    /// <summary>Reveal the mount point in the platform file manager.</summary>
    [RelayCommand]
    private void RevealMount() => _mounter.Reveal();

    private async Task ConnectAsync()
    {
        IsBusy = true;
        ShowReconnect = false;
        StatusText = "Connecting…";
        var typedPassword = ReconnectPassword;
        try
        {
            try { _client?.Disconnect(); _client?.Dispose(); } catch { }
            _client = null;

            var client = await Task.Run(() =>
            {
                var info = RemoteConnection.BuildConnectionInfo(_profile, _password);
                var c = new SftpClient(info);
                c.Connect();
                // Keep the SFTP session alive so idle connections aren't dropped by
                // the server (which later surfaced as "client not connected").
                c.KeepAliveInterval = TimeSpan.FromSeconds(30);
                return c;
            });
            _client = client;
            IsConnected = true;
            ShowReconnect = false;

            // Persist the password the user just typed, if they asked us to.
            if (SavePassword && _passwordSaver is not null && !string.IsNullOrEmpty(typedPassword))
                _passwordSaver(typedPassword);

            ReconnectPassword = "";
            var home = await Task.Run(() => _client.WorkingDirectory);
            await LoadDirectory(string.IsNullOrEmpty(home) ? "." : home);
        }
        catch (Exception ex)
        {
            StatusText = "Connection failed: " + ex.Message;
            IsConnected = false;
            ShowReconnect = true;
        }
        finally
        {
            IsBusy = false;
        }
    }

    /// <summary>Ensure the SFTP session is live, transparently reconnecting when the
    /// server has dropped an idle connection (SSH.NET then throws "client not
    /// connected"). Returns false only when we truly can't (re)connect.</summary>
    private async Task<bool> EnsureConnectedAsync()
    {
        if (_client is null) return false;
        try
        {
            if (!_client.IsConnected)
                await Task.Run(() => _client.Connect());
        }
        catch { /* handled by the IsConnected check below */ }

        if (_client.IsConnected)
        {
            if (!IsConnected) IsConnected = true;
            if (ShowReconnect) ShowReconnect = false;
            return true;
        }

        IsConnected = false;
        ShowReconnect = true;
        StatusText = "Disconnected — reconnect to continue.";
        return false;
    }

    private async Task LoadDirectory(string path)
    {
        if (!await EnsureConnectedAsync()) return;
        IsBusy = true;
        try
        {
            var listing = await Task.Run(() => _client!.ListDirectory(path).ToList());
            var canonical = await Task.Run(() =>
            {
                try { return _client!.Get(path).FullName; } catch { return path; }
            });

            Dispatcher.UIThread.Post(() =>
            {
                CurrentPath = canonical;
                PathInput = canonical;
                RebuildCrumbs(canonical);
                Entries.Clear();
                if (canonical != "/")
                    Entries.Add(new SftpEntryViewModel
                    {
                        Name = "..", FullPath = ParentOf(canonical), IsDirectory = true, IsParent = true
                    });

                foreach (var f in listing
                             .Where(f => f.Name is not "." and not "..")
                             .OrderByDescending(f => f.IsDirectory)
                             .ThenBy(f => f.Name, StringComparer.OrdinalIgnoreCase))
                {
                    Entries.Add(new SftpEntryViewModel
                    {
                        Name = f.Name,
                        FullPath = f.FullName,
                        IsDirectory = f.IsDirectory,
                        Size = f.Length,
                        Modified = f.LastWriteTime,
                        Permissions = PermissionString(f)
                    });
                }
                StatusText = $"{Entries.Count(e => !e.IsParent)} items";
            });
        }
        catch (Exception ex)
        {
            StatusText = "Error: " + ex.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    private static string ParentOf(string path)
    {
        var trimmed = path.TrimEnd('/');
        var idx = trimmed.LastIndexOf('/');
        return idx <= 0 ? "/" : trimmed[..idx];
    }

    /// <summary>Build the clickable breadcrumb from an absolute path.</summary>
    private void RebuildCrumbs(string path)
    {
        Crumbs.Clear();
        Crumbs.Add(new SftpCrumb { Name = "/", FullPath = "/" });
        var acc = "";
        foreach (var seg in path.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            acc += "/" + seg;
            Crumbs.Add(new SftpCrumb { Name = seg, FullPath = acc });
        }
    }

    /// <summary>Render Unix-style permission bits (e.g. <c>rwxr-xr-x</c>) for a listing entry.</summary>
    private static string PermissionString(ISftpFile f)
    {
        char R(bool b) => b ? 'r' : '-';
        char W(bool b) => b ? 'w' : '-';
        char X(bool b) => b ? 'x' : '-';
        var type = f.IsDirectory ? 'd' : f.IsSymbolicLink ? 'l' : '-';
        return $"{type}{R(f.OwnerCanRead)}{W(f.OwnerCanWrite)}{X(f.OwnerCanExecute)}" +
               $"{R(f.GroupCanRead)}{W(f.GroupCanWrite)}{X(f.GroupCanExecute)}" +
               $"{R(f.OthersCanRead)}{W(f.OthersCanWrite)}{X(f.OthersCanExecute)}";
    }

    [RelayCommand]
    private async Task NavigateCrumb(SftpCrumb? crumb)
    {
        if (crumb is not null) await LoadDirectory(crumb.FullPath);
    }

    [RelayCommand]
    private async Task GoToPath()
    {
        var target = (PathInput ?? "").Trim();
        if (target.Length > 0) await LoadDirectory(target);
    }

    [RelayCommand]
    private async Task Rename(SftpEntryViewModel? entry)
    {
        entry ??= SelectedEntry;
        if (entry is null || entry.IsParent || _client is null || NameRequested is null) return;
        var newName = await NameRequested("Rename", entry.Name);
        if (string.IsNullOrWhiteSpace(newName) || newName == entry.Name) return;
        var dest = CurrentPath.TrimEnd('/') + "/" + newName.Trim();
        if (!await EnsureConnectedAsync()) return;
        IsBusy = true;
        try
        {
            await Task.Run(() => _client.RenameFile(entry.FullPath, dest));
            await LoadDirectory(CurrentPath);
        }
        catch (Exception ex) { StatusText = "Rename failed: " + ex.Message; }
        finally { IsBusy = false; }
    }

    [RelayCommand]
    private async Task Open(SftpEntryViewModel? entry)
    {
        entry ??= SelectedEntry;
        if (entry is null) return;
        if (entry.IsDirectory)
            await LoadDirectory(entry.FullPath);
        else
            await Download(entry);
    }

    [RelayCommand]
    private async Task Refresh() => await LoadDirectory(CurrentPath);

    [RelayCommand]
    private async Task GoUp() => await LoadDirectory(ParentOf(CurrentPath));

    [RelayCommand]
    private async Task Download(SftpEntryViewModel? entry)
    {
        entry ??= SelectedEntry;
        if (entry is null || entry.IsDirectory || _client is null) return;
        var dest = await DialogService.SaveFileAsync(entry.Name, "Download " + entry.Name);
        if (string.IsNullOrEmpty(dest)) return;
        if (!await EnsureConnectedAsync()) return;
        IsBusy = true;
        try
        {
            await Task.Run(() =>
            {
                using var fs = File.Create(dest);
                _client.DownloadFile(entry.FullPath, fs);
            });
            StatusText = "Downloaded " + entry.Name;
        }
        catch (Exception ex) { StatusText = "Download failed: " + ex.Message; }
        finally { IsBusy = false; }
    }

    [RelayCommand]
    private async Task Edit(SftpEntryViewModel? entry)
    {
        entry ??= SelectedEntry;
        if (entry is null || entry.IsDirectory || _client is null) return;
        if (!await EnsureConnectedAsync()) return;
        IsBusy = true;
        try
        {
            var text = await Task.Run(() =>
            {
                using var ms = new MemoryStream();
                _client.DownloadFile(entry.FullPath, ms);
                return System.Text.Encoding.UTF8.GetString(ms.ToArray());
            });
            var path = entry.FullPath;
            EditRequested?.Invoke(entry.Name, text, async content =>
            {
                // The editor tab outlives this method, so the SFTP session may have
                // gone idle and been dropped by the time the user saves — reconnect
                // first so the write actually reaches the host.
                if (!await EnsureConnectedAsync())
                    throw new InvalidOperationException(
                        "SFTP disconnected. Reopen the SFTP tab's connection and save again.");
                await Task.Run(() =>
                {
                    var bytes = System.Text.Encoding.UTF8.GetBytes(content);
                    SaveRemoteFile(path, bytes);
                });
                // Reflect the new size/mtime in the listing after a remote save.
                await LoadDirectory(CurrentPath);
            });
            StatusText = "Opened " + entry.Name + " in editor";
        }
        catch (Exception ex) { StatusText = "Open failed: " + ex.Message; }
        finally { IsBusy = false; }
    }

    /// <summary>Write <paramref name="bytes"/> to the remote <paramref name="path"/>.
    /// A straight overwrite needs write permission on the file itself; if that's
    /// denied we fall back to writing a sibling temp file and atomically renaming
    /// it over the target, which only needs write permission on the directory
    /// (e.g. a file owned by another user in a folder you can write). If both are
    /// denied we surface a clear permission message.</summary>
    private void SaveRemoteFile(string path, byte[] bytes)
    {
        try
        {
            using var ms = new MemoryStream(bytes);
            _client!.UploadFile(ms, path, true);
        }
        catch (Renci.SshNet.Common.SftpPermissionDeniedException)
        {
            var slash = path.LastIndexOf('/');
            var dir = slash > 0 ? path[..slash] : ".";
            var name = slash >= 0 ? path[(slash + 1)..] : path;
            var temp = $"{dir}/.{name}.rsedit-{Guid.NewGuid():N}.tmp";
            try
            {
                using (var ms = new MemoryStream(bytes))
                    _client!.UploadFile(ms, temp, true);
            }
            catch (Renci.SshNet.Common.SftpPermissionDeniedException)
            {
                throw new UnauthorizedAccessException(
                    "Permission denied. You don't have write access to this file or its folder on the server.");
            }
            try
            {
                // posix-rename@openssh.com atomically replaces an existing target.
                _client!.RenameFile(temp, path, true);
            }
            catch
            {
                try { _client!.DeleteFile(temp); } catch { /* best effort cleanup */ }
                throw new UnauthorizedAccessException(
                    "Permission denied. You don't have write access to this file on the server.");
            }
        }
    }

    [RelayCommand]
    private async Task Upload()
    {
        if (_client is null) return;
        var src = await DialogService.OpenFileAsync("Upload file");
        if (string.IsNullOrEmpty(src)) return;
        if (!await EnsureConnectedAsync()) return;
        IsBusy = true;
        try
        {
            var remote = CurrentPath.TrimEnd('/') + "/" + Path.GetFileName(src);
            await Task.Run(() =>
            {
                using var fs = File.OpenRead(src);
                _client.UploadFile(fs, remote, true);
            });
            StatusText = "Uploaded " + Path.GetFileName(src);
            await LoadDirectory(CurrentPath);
        }
        catch (Exception ex) { StatusText = "Upload failed: " + ex.Message; }
        finally { IsBusy = false; }
    }

    /// <summary>Upload a local file or folder (recursively) into the current remote
    /// directory. Used by drag-and-drop from the Finder panel or the OS.</summary>
    public async Task UploadLocalPathAsync(string localPath)
    {
        if (string.IsNullOrEmpty(localPath)) return;
        if (!await EnsureConnectedAsync()) return;
        IsBusy = true;
        try
        {
            var name = Path.GetFileName(localPath.TrimEnd('/', '\\'));
            var remote = CurrentPath.TrimEnd('/') + "/" + name;
            await Task.Run(() => UploadRecursive(localPath, remote));
            StatusText = "Uploaded " + name;
            await LoadDirectory(CurrentPath);
        }
        catch (Exception ex) { StatusText = "Upload failed: " + ex.Message; }
        finally { IsBusy = false; }
    }

    private void UploadRecursive(string local, string remote)
    {
        if (Directory.Exists(local))
        {
            try { _client!.CreateDirectory(remote); } catch { /* may already exist */ }
            foreach (var f in Directory.GetFiles(local))
                UploadRecursive(f, remote + "/" + Path.GetFileName(f));
            foreach (var d in Directory.GetDirectories(local))
                UploadRecursive(d, remote + "/" + Path.GetFileName(d));
        }
        else
        {
            using var fs = File.OpenRead(local);
            _client!.UploadFile(fs, remote, true);
        }
    }

    /// <summary>Download a remote file or folder (recursively) into a local directory.
    /// Used by drag-and-drop onto the Finder panel.</summary>
    public async Task DownloadEntryToAsync(SftpEntryViewModel entry, string localDir)
    {
        if (entry.IsParent || string.IsNullOrEmpty(localDir)) return;
        if (!await EnsureConnectedAsync()) return;
        IsBusy = true;
        try
        {
            var dest = Path.Combine(localDir, entry.Name);
            await Task.Run(() => DownloadRecursive(entry.FullPath, entry.IsDirectory, dest));
            StatusText = "Downloaded " + entry.Name;
        }
        catch (Exception ex) { StatusText = "Download failed: " + ex.Message; }
        finally { IsBusy = false; }
    }

    private void DownloadRecursive(string remote, bool isDir, string local)
    {
        if (isDir)
        {
            Directory.CreateDirectory(local);
            foreach (var item in _client!.ListDirectory(remote))
            {
                if (item.Name is "." or "..") continue;
                DownloadRecursive(item.FullName, item.IsDirectory, Path.Combine(local, item.Name));
            }
        }
        else
        {
            using var fs = File.Create(local);
            _client!.DownloadFile(remote, fs);
        }
    }

    [RelayCommand]
    private async Task Delete(SftpEntryViewModel? entry)
    {
        entry ??= SelectedEntry;
        if (entry is null || entry.IsParent || _client is null) return;
        if (!await EnsureConnectedAsync()) return;
        IsBusy = true;
        try
        {
            await Task.Run(() =>
            {
                if (entry.IsDirectory) _client.DeleteDirectory(entry.FullPath);
                else _client.DeleteFile(entry.FullPath);
            });
            await LoadDirectory(CurrentPath);
        }
        catch (Exception ex) { StatusText = "Delete failed: " + ex.Message; }
        finally { IsBusy = false; }
    }

    [RelayCommand]
    private async Task NewFolder()
    {
        if (_client is null) return;
        var name = NameRequested is null ? "new-folder" : await NameRequested("New Folder", "new-folder");
        if (string.IsNullOrWhiteSpace(name)) return;
        var remote = CurrentPath.TrimEnd('/') + "/" + name.Trim();
        if (!await EnsureConnectedAsync()) return;
        IsBusy = true;
        try
        {
            await Task.Run(() => _client.CreateDirectory(remote));
            await LoadDirectory(CurrentPath);
        }
        catch (Exception ex) { StatusText = "Create failed: " + ex.Message; }
        finally { IsBusy = false; }
    }

    [RelayCommand]
    private async Task NewFile()
    {
        if (_client is null) return;
        var name = NameRequested is null ? "new-file.txt" : await NameRequested("New File", "new-file.txt");
        if (string.IsNullOrWhiteSpace(name)) return;
        var remote = CurrentPath.TrimEnd('/') + "/" + name.Trim();
        if (!await EnsureConnectedAsync()) return;
        IsBusy = true;
        try
        {
            await Task.Run(() =>
            {
                using var empty = new MemoryStream();
                _client.UploadFile(empty, remote);
            });
            await LoadDirectory(CurrentPath);
        }
        catch (Exception ex) { StatusText = "Create failed: " + ex.Message; }
        finally { IsBusy = false; }
    }

    public override void Dispose()
    {
        try { _ = _mounter.UnmountAsync(); } catch { /* best-effort */ }
        try { _client?.Disconnect(); _client?.Dispose(); } catch { /* ignore */ }
        _client = null;
    }

    protected override void Close()
    {
        Dispose();
        base.Close();
    }
}
