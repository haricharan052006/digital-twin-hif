param(
  [Parameter(Mandatory = $true)][string]$TitleLike,
  [Parameter(Mandatory = $true)][string]$OutPng,
  [switch]$List
)
# Saves a screenshot of the first top-level window whose title contains
# $TitleLike (used for the Simulink Scope windows, which in R2025a are not
# MATLAB figures). Read-only: it does not move, focus or change the window.
#   powershell -ExecutionPolicy Bypass -File capture_window.ps1 -TitleLike Scope_Isolated_Current -OutPng out.png
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class Win {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr p);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
'@
[void][Win]::SetProcessDPIAware()
$found = New-Object System.Collections.ArrayList
$cb = [Win+EnumProc]{ param($h, $p)
  if ([Win]::IsWindowVisible($h)) {
    $sb = New-Object System.Text.StringBuilder 512
    [void][Win]::GetWindowText($h, $sb, 512)
    $t = $sb.ToString()
    if ($t.Length -gt 0) { [void]$found.Add([pscustomobject]@{ Handle = $h; Title = $t }) }
  }
  return $true }
[void][Win]::EnumWindows($cb, [IntPtr]::Zero)
if ($List) { $found | ForEach-Object { $_.Title }; return }
$w = $found | Where-Object { $_.Title -like "*$TitleLike*" } | Select-Object -First 1
if (-not $w) { throw "no visible window with title containing '$TitleLike'" }
$r = New-Object Win+RECT
[void][Win]::GetWindowRect($w.Handle, [ref]$r)
$bmp = New-Object System.Drawing.Bitmap(($r.R - $r.L), ($r.B - $r.T))
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
[void][Win]::PrintWindow($w.Handle, $hdc, 2)   # PW_RENDERFULLCONTENT
$g.ReleaseHdc($hdc)
$bmp.Save($OutPng, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"captured '$($w.Title)' $($r.R - $r.L)x$($r.B - $r.T) -> $OutPng"
