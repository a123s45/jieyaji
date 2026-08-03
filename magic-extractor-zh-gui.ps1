#requires -version 5.1
param([switch]$SelfTest)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$cs = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

public static class TranslucencyHelper
{
    public static void PaintParentBackground(Control c, Graphics g)
    {
        Form f = c.FindForm();
        if (f == null || f.BackgroundImage == null)
        {
            using (SolidBrush b = new SolidBrush(Color.White))
            {
                g.FillRectangle(b, c.ClientRectangle);
            }
            return;
        }
        Image img = f.BackgroundImage;
        Rectangle formClient = f.ClientRectangle;
        Rectangle panelScreen = c.RectangleToScreen(c.ClientRectangle);
        Rectangle formScreen = f.RectangleToScreen(formClient);
        Rectangle panelOnForm = new Rectangle(panelScreen.X - formScreen.X, panelScreen.Y - formScreen.Y, c.ClientRectangle.Width, c.ClientRectangle.Height);
        float scale = Math.Min((float)formClient.Width / img.Width, (float)formClient.Height / img.Height);
        int drawW = (int)(img.Width * scale);
        int drawH = (int)(img.Height * scale);
        int drawX = (formClient.Width - drawW) / 2;
        int drawY = (formClient.Height - drawH) / 2;
        Rectangle drawn = new Rectangle(drawX, drawY, drawW, drawH);
        Rectangle clip = Rectangle.Intersect(panelOnForm, drawn);
        if (clip.IsEmpty) return;
        int srcX = (int)((long)(clip.X - drawn.X) * img.Width / drawn.Width);
        int srcY = (int)((long)(clip.Y - drawn.Y) * img.Height / drawn.Height);
        int srcW = (int)((long)clip.Width * img.Width / drawn.Width);
        int srcH = (int)((long)clip.Height * img.Height / drawn.Height);
        Rectangle src = new Rectangle(srcX, srcY, srcW, srcH);
        Rectangle dest = new Rectangle(clip.X - panelOnForm.X, clip.Y - panelOnForm.Y, clip.Width, clip.Height);
        g.DrawImage(img, dest, src, GraphicsUnit.Pixel);
    }
}

public class TranslucentPanel : Panel
{
    public int Opacity { get; set; }
    public Color TintColor { get; set; }

    public TranslucentPanel()
    {
        Opacity = 200;
        TintColor = Color.White;
        SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        BackColor = Color.Transparent;
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        PaintBack(e.Graphics);
    }

    private void PaintBack(Graphics g)
    {
        TranslucencyHelper.PaintParentBackground(this, g);
        using (SolidBrush b = new SolidBrush(Color.FromArgb(Opacity, TintColor)))
        {
            g.FillRectangle(b, ClientRectangle);
        }
    }
}

public class TranslucentButton : Button
{
    public int Opacity { get; set; }
    public Color TintColor { get; set; }

    public TranslucentButton()
    {
        Opacity = 128;
        TintColor = Color.White;
        SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        BackColor = Color.Transparent;
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        TranslucencyHelper.PaintParentBackground(this, g);
        Color tint = TintColor;
        if (Capture)
        {
            tint = Color.FromArgb(255, 150, 180, 230);
        }
        else if (ClientRectangle.Contains(PointToClient(Cursor.Position)))
        {
            tint = Color.FromArgb(255, 225, 235, 250);
        }
        using (SolidBrush b = new SolidBrush(Color.FromArgb(Opacity, tint)))
        {
            g.FillRectangle(b, ClientRectangle);
        }
        TextRenderer.DrawText(g, Text, Font, ClientRectangle, ForeColor, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
    }
}

public class TransparentListBox : Control
{
    public int Opacity { get; set; }
    public Color TintColor { get; set; }

    private readonly List<string> _items = new List<string>();
    private readonly VScrollBar _vbar = new VScrollBar();
    private int _scroll;
    public event Action<string> ItemRemoved;

    public TransparentListBox()
    {
        Opacity = 128;
        TintColor = Color.White;
        SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        BackColor = Color.Transparent;
        _vbar.Dock = DockStyle.Right;
        _vbar.Visible = false;
        _vbar.Scroll += delegate(object sender, ScrollEventArgs e) { _scroll = _vbar.Value; Invalidate(); };
        Controls.Add(_vbar);
        Resize += delegate(object sender, EventArgs e) { UpdateScrollbar(); };
    }

    public void AddItem(string text)
    {
        _items.Add(text);
        UpdateScrollbar();
        Invalidate();
    }

    public void ClearItems()
    {
        _items.Clear();
        _scroll = 0;
        UpdateScrollbar();
        Invalidate();
    }

    private int ItemHeight
    {
        get { return Math.Max(20, Font.Height + 4); }
    }

    private int LinesVisible()
    {
        return Math.Max(1, ClientRectangle.Height / ItemHeight);
    }

    private void UpdateScrollbar()
    {
        int maxScroll = Math.Max(0, _items.Count - LinesVisible());
        _vbar.Minimum = 0;
        _vbar.Maximum = Math.Max(0, _items.Count);
        _vbar.LargeChange = Math.Max(1, LinesVisible());
        _vbar.SmallChange = 1;
        _vbar.Visible = maxScroll > 0;
        if (_scroll > maxScroll) { _scroll = maxScroll; }
        _vbar.Value = _scroll;
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        TranslucencyHelper.PaintParentBackground(this, e.Graphics);
        using (SolidBrush b = new SolidBrush(Color.FromArgb(Opacity, TintColor)))
        {
            e.Graphics.FillRectangle(b, ClientRectangle);
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        int itemH = ItemHeight;
        int visible = LinesVisible();
        int width = ClientRectangle.Width - (_vbar.Visible ? _vbar.Width : 0) - 6;
        for (int i = _scroll; i < _items.Count && i < _scroll + visible; i++)
        {
            Rectangle r = new Rectangle(3, (i - _scroll) * itemH + 2, width, itemH);
            TextRenderer.DrawText(e.Graphics, _items[i], Font, r, ForeColor, TextFormatFlags.EndEllipsis | TextFormatFlags.VerticalCenter);
        }
    }

    protected override void OnMouseClick(MouseEventArgs e)
    {
        int ix = _scroll + e.Y / ItemHeight;
        if (ix >= 0 && ix < _items.Count)
        {
            string removed = _items[ix];
            _items.RemoveAt(ix);
            if (_scroll > Math.Max(0, _items.Count - LinesVisible()))
            {
                _scroll = Math.Max(0, _items.Count - LinesVisible());
            }
            UpdateScrollbar();
            Invalidate();
            if (ItemRemoved != null)
            {
                ItemRemoved(removed);
            }
        }
        base.OnMouseClick(e);
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        int maxScroll = Math.Max(0, _items.Count - LinesVisible());
        int delta = e.Delta > 0 ? -1 : 1;
        _scroll = Math.Max(0, Math.Min(maxScroll, _scroll + delta));
        _vbar.Value = _scroll;
        Invalidate();
        base.OnMouseWheel(e);
    }
}

public class TransparentLogBox : Control
{
    public int Opacity { get; set; }
    public Color TintColor { get; set; }

    private readonly List<string> _lines = new List<string>();
    private readonly VScrollBar _vbar = new VScrollBar();
    private int _scroll;

    public TransparentLogBox()
    {
        Opacity = 128;
        TintColor = Color.White;
        SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        BackColor = Color.Transparent;
        _vbar.Dock = DockStyle.Right;
        _vbar.Visible = false;
        _vbar.Scroll += delegate(object sender, ScrollEventArgs e) { _scroll = _vbar.Value; Invalidate(); };
        Controls.Add(_vbar);
        Resize += delegate(object sender, EventArgs e) { UpdateScrollbar(); };
    }

    public void AddLine(string text)
    {
        string[] parts = text.Split('\n');
        foreach (string part in parts)
        {
            _lines.Add(part.TrimEnd('\r'));
        }
        if (_lines.Count > 2000)
        {
            _lines.RemoveRange(0, _lines.Count - 2000);
        }
        UpdateScrollbar();
        _scroll = Math.Max(0, _lines.Count - LinesVisible());
        _vbar.Value = _scroll;
        Invalidate();
    }

    private int LineHeight
    {
        get { return Math.Max(16, Font.Height + 2); }
    }

    private int LinesVisible()
    {
        return Math.Max(1, ClientRectangle.Height / LineHeight);
    }

    private void UpdateScrollbar()
    {
        int maxScroll = Math.Max(0, _lines.Count - LinesVisible());
        _vbar.Minimum = 0;
        _vbar.Maximum = Math.Max(0, _lines.Count);
        _vbar.LargeChange = Math.Max(1, LinesVisible());
        _vbar.SmallChange = 1;
        _vbar.Visible = maxScroll > 0;
        if (_scroll > maxScroll) { _scroll = maxScroll; }
        _vbar.Value = _scroll;
    }

    private List<string> WrapLines()
    {
        List<string> result = new List<string>();
        int width = Math.Max(50, ClientRectangle.Width - (_vbar.Visible ? _vbar.Width : 0) - 6);
        foreach (string line in _lines)
        {
            if (string.IsNullOrEmpty(line))
            {
                result.Add(string.Empty);
                continue;
            }
            string current = line;
            while (current.Length > 0)
            {
                int take = current.Length;
                while (take > 1 && TextRenderer.MeasureText(current.Substring(0, take), Font).Width > width)
                {
                    take--;
                }
                result.Add(current.Substring(0, take));
                current = current.Substring(take);
            }
        }
        return result;
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        TranslucencyHelper.PaintParentBackground(this, e.Graphics);
        using (SolidBrush b = new SolidBrush(Color.FromArgb(Opacity, TintColor)))
        {
            e.Graphics.FillRectangle(b, ClientRectangle);
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        List<string> wrapped = WrapLines();
        int lineH = LineHeight;
        int visible = LinesVisible();
        int width = ClientRectangle.Width - (_vbar.Visible ? _vbar.Width : 0) - 6;
        for (int i = _scroll; i < wrapped.Count && i < _scroll + visible; i++)
        {
            Rectangle r = new Rectangle(3, (i - _scroll) * lineH + 2, width, lineH);
            TextRenderer.DrawText(e.Graphics, wrapped[i], Font, r, ForeColor, TextFormatFlags.EndEllipsis | TextFormatFlags.VerticalCenter);
        }
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        List<string> wrapped = WrapLines();
        int maxScroll = Math.Max(0, wrapped.Count - LinesVisible());
        int delta = e.Delta > 0 ? -1 : 1;
        _scroll = Math.Max(0, Math.Min(maxScroll, _scroll + delta));
        _vbar.Value = _scroll;
        Invalidate();
        base.OnMouseWheel(e);
    }
}
'@

$refs = @(
    [System.Windows.Forms.Application].Assembly.Location,
    [System.Drawing.Image].Assembly.Location
)
Add-Type -TypeDefinition $cs -ReferencedAssemblies $refs

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$MagicExe = 'D:\解压姬\magic-extractor.exe'
$DefaultPwFile = 'D:\解压姬\passwords.txt'
$ConfigPath = 'D:\解压姬\gui_config.ini'
$BgFolder = 'D:\解压姬\backgrounds'
$WorkerScript = 'D:\解压姬\extract-worker.ps1'

$script:queue = [System.Collections.Generic.List[string]]::new()
$script:busy = $false
$script:currentBg = $null
$script:panels = [System.Collections.Generic.List[System.Windows.Forms.Control]]::new()
$script:queueIndex = 0
$script:workerRunning = @{}
$script:workerDone = 0
$script:workerOk = 0
$script:workerTotal = 0
$script:threadCount = 1
$script:config = @{
    x = '-1'
    y = '-1'
    width = '860'
    height = '620'
    background = ''
    panel_color = '255,255,255'
}

function Write-LogBox([string]$text) {
    if ($script:logBox) {
        $script:logBox.AddLine($text)
    }
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return }
    foreach ($line in (Get-Content -LiteralPath $ConfigPath -Encoding UTF8)) {
        if ($line -match '^([^=]+)=(.*)$') {
            $script:config[$matches[1].Trim()] = $matches[2].Trim()
        }
    }
}

function Write-Config {
    $lines = foreach ($k in $script:config.Keys) {
        "$k=$($script:config[$k])"
    }
    Set-Content -LiteralPath $ConfigPath -Value $lines -Encoding UTF8
}

function Read-PasswordList([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $lines = [System.IO.File]::ReadAllLines($path)
    $attempts = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($l in $lines) {
        if ($null -eq $l) { continue }
        if ($l -ne '' -and $seen.Add($l)) { $attempts.Add($l) }
        $t = $l.Trim()
        if ($t -ne '' -and $t -ne $l -and $seen.Add($t)) { $attempts.Add($t) }
    }
    return $attempts
}

function Test-ExtractPassword([string]$file, [string]$outDir, [string]$pw) {
    if ($pw -eq '') {
        $pw = '__jieyaji_no_password__'
    }
    & $MagicExe extract $file $outDir --password $pw 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
}

function Move-Contents([string]$src, [string]$dst) {
    Get-ChildItem -LiteralPath $src -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Move-Item -LiteralPath $_.FullName -Destination $dst -Force -ErrorAction Stop
    }
}

function Collapse-Nested([string]$dir, [string]$baseName) {
    while ($true) {
        $children = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
        $dirs = @($children | Where-Object { $_.PSIsContainer })
        $files = @($children | Where-Object { -not $_.PSIsContainer })
        if ($files.Count -eq 0 -and $dirs.Count -eq 1) {
            $innerName = $dirs[0].Name
            $leaf = Split-Path $dir -Leaf
            if ($innerName -eq $baseName -or $innerName -eq $leaf) {
                $inner = $dirs[0].FullName
                Move-Contents $inner $dir
                [System.IO.Directory]::Delete($inner, $true)
                continue
            }
        }
        break
    }
}

function Resolve-OutputDir([string]$file) {
    $parent = Split-Path $file -Parent
    $base = [System.IO.Path]::GetFileNameWithoutExtension($file)
    $candidate = Join-Path $parent $base
    $n = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $parent ($base + ' (' + $n + ')')
        $n++
    }
    return $candidate
}

function Process-File([string]$file, [string]$pwFile, [bool]$collapse) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($file)
    $temp = Join-Path $env:TEMP ('zh_extract_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    Write-LogBox "正在识别: $file"
    try {
        $ok = Test-ExtractPassword $file $temp ''
        if (-not $ok) {
            $attempts = Read-PasswordList $pwFile
            for ($i = 0; $i -lt $attempts.Count; $i++) {
                Write-LogBox "正在尝试密码 $($i + 1)/$($attempts.Count)"
                if (Test-ExtractPassword $file $temp $attempts[$i]) {
                    $ok = $true
                    Write-LogBox "密码匹配: $($attempts[$i])"
                    break
                }
            }
        } else {
            Write-LogBox '无需密码，已解压'
        }

        if (-not $ok) {
            Write-LogBox "失败: $file (密码本未命中)"
            return $false
        }

        $final = Resolve-OutputDir $file
        New-Item -ItemType Directory -Path $final -Force | Out-Null
        Move-Contents $temp $final
        if ($collapse) {
            Collapse-Nested $final $base
        }
        Write-LogBox "完成: $final"
        return $true
    } finally {
        if (Test-Path -LiteralPath $temp) {
            [System.IO.Directory]::Delete($temp, $true)
        }
    }
}

function Add-ToQueue([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.PSIsContainer) {
        Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not $script:queue.Contains($_.FullName)) {
                $script:queue.Add($_.FullName)
                $script:queueBox.AddItem($_.FullName)
            }
        }
    } else {
        if (-not $script:queue.Contains($item.FullName)) {
            $script:queue.Add($item.FullName)
            $script:queueBox.AddItem($item.FullName)
        }
    }
}

function Set-BackgroundImage([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        $script:form.BackgroundImage = $null
        return
    }
    try {
        $img = [System.Drawing.Image]::FromFile($path)
        if ($script:currentBg) { $script:currentBg.Dispose() }
        $script:currentBg = $img
        $script:form.BackgroundImage = $img
        $script:form.BackgroundImageLayout = [System.Windows.Forms.ImageLayout]::Zoom
    } catch {
        Write-LogBox ('背景图加载失败: ' + $_.Exception.Message)
    }
}

function Apply-PanelStyle {
    $parts = ([string]$script:config['panel_color']) -split ','
    if ($parts.Count -eq 3) {
        $script:panelColor = [System.Drawing.Color]::FromArgb([int]$parts[0], [int]$parts[1], [int]$parts[2])
    } else {
        $script:panelColor = [System.Drawing.Color]::White
    }
    foreach ($p in $script:panels) {
        $p.TintColor = $script:panelColor
        $p.Opacity = 128
    }
}

$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = '解压姬 - 万能解压助手'
$script:form.StartPosition = 'CenterScreen'
$script:form.MinimumSize = New-Object System.Drawing.Size(720, 520)
$script:form.BackColor = [System.Drawing.Color]::White
$script:form.ForeColor = [System.Drawing.Color]::FromArgb(30, 35, 45)
$script:form.AllowDrop = $true

$topPanel = New-Object TranslucentPanel
$topPanel.Location = New-Object System.Drawing.Point(0, 0)
$topPanel.Size = New-Object System.Drawing.Size(1000, 90)
$topPanel.Anchor = 'Top,Left,Right'
$script:form.Controls.Add($topPanel)
$script:panels.Add($topPanel)

$title = New-Object System.Windows.Forms.Label
$title.Text = '解压姬'
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 22, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::FromArgb(25, 60, 110)
$title.AutoSize = $true
$title.BackColor = [System.Drawing.Color]::Transparent
$title.Location = New-Object System.Drawing.Point(24, 14)
$topPanel.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = '拖入文件，自动识别真实格式并按密码本解压到同名目录'
$subtitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(60, 70, 85)
$subtitle.AutoSize = $true
$subtitle.BackColor = [System.Drawing.Color]::Transparent
$subtitle.Location = New-Object System.Drawing.Point(26, 58)
$topPanel.Controls.Add($subtitle)

$leftPanel = New-Object TranslucentPanel
$leftPanel.Location = New-Object System.Drawing.Point(20, 108)
$leftPanel.Size = New-Object System.Drawing.Size(250, 440)
$script:form.Controls.Add($leftPanel)
$script:panels.Add($leftPanel)

$btnAdd = New-Object TranslucentButton
$btnAdd.Text = '添加文件'
$btnAdd.Size = New-Object System.Drawing.Size(210, 36)
$btnAdd.Location = New-Object System.Drawing.Point(20, 18)
$btnAdd.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$btnAdd.ForeColor = [System.Drawing.Color]::FromArgb(25, 60, 110)
$leftPanel.Controls.Add($btnAdd)

$btnClear = New-Object TranslucentButton
$btnClear.Text = '清空列表'
$btnClear.Size = New-Object System.Drawing.Size(210, 36)
$btnClear.Location = New-Object System.Drawing.Point(20, 62)
$btnClear.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$btnClear.ForeColor = [System.Drawing.Color]::FromArgb(25, 60, 110)
$leftPanel.Controls.Add($btnClear)

$btnStart = New-Object TranslucentButton
$btnStart.Text = '开始解压'
$btnStart.Size = New-Object System.Drawing.Size(210, 44)
$btnStart.Location = New-Object System.Drawing.Point(20, 110)
$btnStart.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
$btnStart.TintColor = [System.Drawing.Color]::FromArgb(255, 150, 200, 255)
$btnStart.ForeColor = [System.Drawing.Color]::FromArgb(15, 45, 90)
$leftPanel.Controls.Add($btnStart)

$collapseCheck = New-Object System.Windows.Forms.CheckBox
$collapseCheck.Text = '解压后折叠同名目录'
$collapseCheck.Checked = $true
$collapseCheck.ForeColor = [System.Drawing.Color]::FromArgb(30, 40, 55)
$collapseCheck.AutoSize = $true
$collapseCheck.BackColor = [System.Drawing.Color]::Transparent
$collapseCheck.Location = New-Object System.Drawing.Point(20, 166)
$collapseCheck.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$leftPanel.Controls.Add($collapseCheck)

$pwLabel = New-Object System.Windows.Forms.Label
$pwLabel.Text = '密码本:'
$pwLabel.ForeColor = [System.Drawing.Color]::FromArgb(30, 40, 55)
$pwLabel.AutoSize = $true
$pwLabel.BackColor = [System.Drawing.Color]::Transparent
$pwLabel.Location = New-Object System.Drawing.Point(20, 204)
$pwLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$leftPanel.Controls.Add($pwLabel)

$pwBox = New-Object System.Windows.Forms.TextBox
$pwBox.Text = $DefaultPwFile
$pwBox.Size = New-Object System.Drawing.Size(210, 24)
$pwBox.Location = New-Object System.Drawing.Point(20, 228)
$pwBox.BackColor = [System.Drawing.Color]::White
$pwBox.BorderStyle = 'FixedSingle'
$leftPanel.Controls.Add($pwBox)

$threadLabel = New-Object System.Windows.Forms.Label
$threadLabel.Text = '解压线程:'
$threadLabel.ForeColor = [System.Drawing.Color]::FromArgb(30, 40, 55)
$threadLabel.AutoSize = $true
$threadLabel.BackColor = [System.Drawing.Color]::Transparent
$threadLabel.Location = New-Object System.Drawing.Point(20, 262)
$threadLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$leftPanel.Controls.Add($threadLabel)

$threadBox = New-Object System.Windows.Forms.NumericUpDown
$threadBox.Minimum = 1
$threadBox.Maximum = 8
$threadBox.Value = 1
$threadBox.Size = New-Object System.Drawing.Size(70, 24)
$threadBox.Location = New-Object System.Drawing.Point(95, 260)
$threadBox.BackColor = [System.Drawing.Color]::White
$leftPanel.Controls.Add($threadBox)

$btnBg = New-Object TranslucentButton
$btnBg.Text = '切换背景图'
$btnBg.Size = New-Object System.Drawing.Size(210, 36)
$btnBg.Location = New-Object System.Drawing.Point(20, 306)
$btnBg.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$btnBg.ForeColor = [System.Drawing.Color]::FromArgb(25, 60, 110)
$leftPanel.Controls.Add($btnBg)

$btnColor = New-Object TranslucentButton
$btnColor.Text = '面板颜色'
$btnColor.Size = New-Object System.Drawing.Size(210, 36)
$btnColor.Location = New-Object System.Drawing.Point(20, 350)
$btnColor.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$btnColor.ForeColor = [System.Drawing.Color]::FromArgb(25, 60, 110)
$leftPanel.Controls.Add($btnColor)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = '支持批量拖入文件或文件夹，解压到文件所在位置的同名文件夹。'
$hint.ForeColor = [System.Drawing.Color]::FromArgb(70, 80, 95)
$hint.Location = New-Object System.Drawing.Point(20, 396)
$hint.Size = New-Object System.Drawing.Size(210, 80)
$hint.BackColor = [System.Drawing.Color]::Transparent
$hint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$leftPanel.Controls.Add($hint)

$script:queueBox = New-Object TransparentListBox
$script:queueBox.Location = New-Object System.Drawing.Point(290, 108)
$script:queueBox.Size = New-Object System.Drawing.Size(550, 180)
$script:queueBox.AllowDrop = $true
$script:queueBox.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$script:queueBox.ForeColor = [System.Drawing.Color]::FromArgb(30, 40, 55)
$script:queueBox.Anchor = 'Top,Left,Right'
$script:form.Controls.Add($script:queueBox)
$script:queueBox.add_ItemRemoved([Action[string]]{ param($path) $script:queue.Remove([string]$path) })

$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = '运行日志'
$logLabel.ForeColor = [System.Drawing.Color]::FromArgb(25, 60, 110)
$logLabel.AutoSize = $true
$logLabel.BackColor = [System.Drawing.Color]::Transparent
$logLabel.Location = New-Object System.Drawing.Point(290, 298)
$logLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$logLabel.Anchor = 'Top,Left,Right'
$script:form.Controls.Add($logLabel)

$script:logBox = New-Object TransparentLogBox
$script:logBox.Location = New-Object System.Drawing.Point(290, 326)
$script:logBox.Size = New-Object System.Drawing.Size(550, 190)
$script:logBox.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$script:logBox.ForeColor = [System.Drawing.Color]::FromArgb(30, 40, 55)
$script:logBox.Anchor = 'Top,Left,Right,Bottom'
$script:form.Controls.Add($script:logBox)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(290, 532)
$progressBar.Size = New-Object System.Drawing.Size(550, 22)
$progressBar.Anchor = 'Bottom,Left,Right'
$script:form.Controls.Add($progressBar)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = '就绪'
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(60, 70, 85)
$statusLabel.AutoSize = $true
$statusLabel.BackColor = [System.Drawing.Color]::Transparent
$statusLabel.Location = New-Object System.Drawing.Point(290, 564)
$statusLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$statusLabel.Anchor = 'Bottom,Left'
$script:form.Controls.Add($statusLabel)

$dragEnter = {
    param($s, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
}

$dragDrop = {
    param($s, $e)
    $files = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    foreach ($f in $files) {
        Add-ToQueue $f
    }
    Write-LogBox ("已加入队列: " + $files.Count + " 个条目")
}

$script:form.Add_DragEnter($dragEnter)
$script:form.Add_DragDrop($dragDrop)
$script:queueBox.Add_DragEnter($dragEnter)
$script:queueBox.Add_DragDrop($dragDrop)

$btnAdd.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Multiselect = $true
    $dlg.Filter = '所有文件 (*.*)|*.*'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        foreach ($f in $dlg.FileNames) {
            Add-ToQueue $f
        }
        Write-LogBox ("已添加 " + $dlg.FileNames.Count + " 个文件")
    }
})

$btnClear.Add_Click({
    $script:queue.Clear()
    $script:queueBox.ClearItems()
    Write-LogBox '已清空列表'
})

$btnBg.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = '图片文件 (*.jpg;*.jpeg;*.png;*.bmp;*.gif)|*.jpg;*.jpeg;*.png;*.bmp;*.gif'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        New-Item -ItemType Directory -Path $BgFolder -Force | Out-Null
        $ext = [System.IO.Path]::GetExtension($dlg.FileName)
        $destName = 'bg_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + $ext
        $dest = Join-Path $BgFolder $destName
        Copy-Item -LiteralPath $dlg.FileName -Destination $dest -Force
        Set-BackgroundImage $dest
        $script:config['background'] = $dest
        Write-Config
        Write-LogBox ('已导入背景: ' + $dest)
    }
})

$btnColor.Add_Click({
    $dlg = New-Object System.Windows.Forms.ColorDialog
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:panelColor = $dlg.Color
        foreach ($p in $script:panels) {
            $p.TintColor = $script:panelColor
        }
        $script:config['panel_color'] = '{0},{1},{2}' -f $script:panelColor.R, $script:panelColor.G, $script:panelColor.B
        Write-Config
    }
})

function Start-NextWorker {
    $file = $script:queue[$script:queueIndex]
    $script:queueIndex++
    $log = Join-Path $env:TEMP ('jieyaji_worker_' + [guid]::NewGuid().ToString('N') + '.log')
    $argItems = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $WorkerScript, '-FilePath', $file, '-PasswordFile', $pwBox.Text, '-MagicExe', $MagicExe, '-LogFile', $log)
    if ($collapseCheck.Checked) {
        $argItems += '-Collapse'
    }
    $cmdLine = (($argItems | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' ')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.Arguments = $cmdLine
    $proc = [System.Diagnostics.Process]::Start($psi)
    $script:workerRunning[$proc.Id] = @{ File = $file; Log = $log }
    Write-LogBox ("已启动: " + $file)
}

function Update-Workers {
    $finished = @()
    foreach ($pidKey in $script:workerRunning.Keys) {
        $proc = Get-Process -Id $pidKey -ErrorAction SilentlyContinue
        if ($null -eq $proc -or $proc.HasExited) {
            $finished += $pidKey
        }
    }
    foreach ($pidKey in $finished) {
        $rec = $script:workerRunning[$pidKey]
        $success = $false
        if (Test-Path -LiteralPath $rec.Log) {
            $lines = @(Get-Content -LiteralPath $rec.Log -Encoding UTF8)
            foreach ($line in $lines) {
                Write-LogBox $line
                if ($line -match '^DONE ') {
                    $success = $true
                }
            }
            [System.IO.File]::Delete($rec.Log)
        }
        if ($success) {
            $script:workerOk++
        }
        $script:workerDone++
        $script:workerRunning.Remove($pidKey)
    }
    while ($script:workerRunning.Count -lt $script:threadCount -and $script:queueIndex -lt $script:workerTotal) {
        Start-NextWorker
    }
    if ($script:workerDone -gt 0 -and $script:workerTotal -gt 0) {
        $progressBar.Value = [int]($script:workerDone * 100 / $script:workerTotal)
        $statusLabel.Text = "$script:workerDone/$script:workerTotal 完成"
    }
    if ($script:workerDone -eq $script:workerTotal -and $script:workerRunning.Count -eq 0) {
        $workerTimer.Stop()
        $script:busy = $false
        $btnStart.Enabled = $true
        $result = "$script:workerOk/$script:workerTotal 个文件解压成功"
        Write-LogBox $result
        $statusLabel.Text = $result
        [System.Windows.Forms.MessageBox]::Show($result, '解压姬', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        $progressBar.Value = 0
    }
}

$workerTimer = New-Object System.Windows.Forms.Timer
$workerTimer.Interval = 300
$workerTimer.add_Tick({ Update-Workers })

$btnStart.Add_Click({
    if ($script:busy) { return }
    if ($script:queue.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('请先添加文件或拖入文件', '解压姬', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    if (-not (Test-Path -LiteralPath $pwBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show('密码本不存在: ' + $pwBox.Text, '解压姬', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $script:busy = $true
    $btnStart.Enabled = $false
    $script:queueIndex = 0
    $script:workerRunning.Clear()
    $script:workerDone = 0
    $script:workerOk = 0
    $script:workerTotal = $script:queue.Count
    $script:threadCount = [int]$threadBox.Value
    $statusLabel.Text = '正在解压...'
    $workerTimer.Start()
    Update-Workers
})

$script:form.Add_FormClosing({
    $script:config['x'] = $script:form.Location.X
    $script:config['y'] = $script:form.Location.Y
    $script:config['width'] = $script:form.Size.Width
    $script:config['height'] = $script:form.Size.Height
    $script:config['panel_color'] = '{0},{1},{2}' -f $script:panelColor.R, $script:panelColor.G, $script:panelColor.B
    if ($script:currentBg) {
        $script:currentBg.Dispose()
        $script:currentBg = $null
    }
    Write-Config
})

Read-Config
Apply-PanelStyle

$w = [int]$script:config['width']
$h = [int]$script:config['height']
if ($w -ge 720 -and $h -ge 520) {
    $script:form.Size = New-Object System.Drawing.Size($w, $h)
}
$x = [int]$script:config['x']
$y = [int]$script:config['y']
if ($x -ge 0 -and $y -ge 0) {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($x -lt ($vs.Right - 100) -and $y -lt ($vs.Bottom - 100)) {
        $script:form.StartPosition = 'Manual'
        $script:form.Location = New-Object System.Drawing.Point($x, $y)
    }
}

if ([string]$script:config['background']) {
    Set-BackgroundImage ([string]$script:config['background'])
}

if ($SelfTest) {
    $testRoot = Join-Path $env:TEMP ('jieyaji_selftest_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $testRoot 'abc') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $testRoot 'abc\secret.txt') -Value 'hello' -Encoding UTF8
    $fake = Join-Path $testRoot 'abc.mp4'
    $pwFile = Join-Path $testRoot 'pw.txt'
    Set-Content -LiteralPath $pwFile -Value @('wrongpw', '123456') -Encoding UTF8
    & 'D:\解压姬\bin\extractors\7z\7z.exe' a -tzip -p123456 $fake (Join-Path $testRoot 'abc\secret.txt') | Out-Null
    $tempOut = Join-Path $testRoot 'temp_out'
    New-Item -ItemType Directory -Path $tempOut -Force | Out-Null
    $ok = $false
    $attempts = Read-PasswordList $pwFile
    foreach ($pw in $attempts) {
        if (Test-ExtractPassword $fake $tempOut $pw) {
            $ok = $true
            break
        }
    }
    $final = Join-Path $testRoot 'result'
    if ($ok) {
        New-Item -ItemType Directory -Path $final -Force | Out-Null
        Move-Contents $tempOut $final
        Collapse-Nested $final 'abc'
    }
    $flat = Test-Path -LiteralPath (Join-Path $final 'secret.txt')
    $nested = Test-Path -LiteralPath (Join-Path $final 'abc\secret.txt')
    if ($ok -and $flat -and -not $nested) {
        Write-Host 'SELFTEST OK'
        [System.IO.Directory]::Delete($testRoot, $true)
        exit 0
    }
    Write-Host "SELFTEST FAIL ok=$ok flat=$flat nested=$nested"
    [System.IO.Directory]::Delete($testRoot, $true)
    exit 1
}

$script:form.Add_Shown({
    Write-LogBox '解压姬已启动，请拖入文件开始。'
})

try {
    $script:form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($MagicExe)
} catch {}

[System.Windows.Forms.Application]::Run($script:form)
