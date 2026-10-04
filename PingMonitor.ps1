
#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateRange(0, 3600)] [int]$Interval = 4,
    [ValidateRange(0, 65500)] [int]$BufferSize = 32,
    [ValidateRange(1, 2147483647)] [int]$Timeout = 1000,
    [ValidateRange(0, 20)] [int]$HistoryDepth = 7,
    [ValidateSet('Light', 'Dark', 'System')] [string]$Theme = 'System',
    [switch]$OnTop,
    [switch]$HideConsole
)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$ExternalInvocation = $MyInvocation.CommandOrigin -eq 'Internal' -or $MyInvocation.InvocationName -eq '&'
#region 00.Config

# ---- App identity ---------------------------------------------------------
$script:AppUserModelId = 'HK.WPF.PingMonitor'
# ---- Graph / UI geometry (themes must NOT override these) ------------------
$script:Config = [pscustomobject]@{
    GraphWidth       = 240.0
    GraphHeight      = 60.0
    GraphMaxRttMs    = 300.0      # RTT value that fills the graph to 100% height
    GraphBarGap      = 2.0
    GraphMinBarHeight= 5.0
    GraphErrorBarHeight = 2.0
    DragThresholdPx  = 5          # mouse movement needed before a card/row drag starts
    InsertBeforeWeight = 0.8      # left 80% of a card inserts-before, right 20% inserts-after
    MaxConcurrentPings = 20
    RttWarningMs     = 150        # > this  -> amber
    RttCriticalMs    = 250        # > this  -> red
    ToolbarLabelWidthBreak = 462     # below this window width, toolbar/status text labels hide
    ScrollBarWidth   = 10         # themed scrollbar track width (thumb-only, no arrow buttons)
}
# ---- Default monitoring settings (overridable by CLI params / config file) -
function New-DefaultSettings {
    param(
        [int]$Interval     = 4,
        [int]$Timeout      = 1000,
        [int]$BufferSize   = 32,
        [int]$HistoryDepth = 7,
        [int]$Ttl          = 128,
        [bool]$DontFragment = $false
    )
    [pscustomobject]@{
        Interval     = $Interval
        Timeout      = $Timeout
        BufferSize   = $BufferSize
        HistoryDepth = $HistoryDepth
        Ttl          = $Ttl
        DontFragment = $DontFragment
    }
}
function Get-ConfigPath {
    $scriptPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $scriptPath = $MyInvocation.MyCommand.Path
    }
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        return (Join-Path $PWD 'PingMonitor.json')
    }
    $directory = Split-Path -Parent $scriptPath
    $name = [IO.Path]::GetFileNameWithoutExtension($scriptPath)
    Join-Path $directory "$name.json"
}
#endregion
#region 01.Native
<#
    Any native code should be added to this single class.
#>
if (-not ('PingMonitor.NativeMethods' -as [type])) {
    $nativeCode = @'
using System;
using System.Runtime.InteropServices;
namespace PingMonitor
{
    public static class NativeMethods
    {
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr handle, int command);
        [DllImport("dwmapi.dll")]   public static extern int DwmSetWindowAttribute(
            IntPtr hwnd, int attribute, ref int value, int valueSize);
    }
    public class TaskbarFix
    {
        [DllImport("shell32.dll")]  public static extern int SetCurrentProcessExplicitAppUserModelID(
            [MarshalAs(UnmanagedType.LPWStr)] string AppID);
    }
}
'@
    try {
        Add-Type -TypeDefinition $nativeCode -ErrorAction Stop
    }
    catch {
        Write-Verbose "Native helper type could not be compiled: $($_.Exception.Message)"
    }
}
try {
    [void][PingMonitor.TaskbarFix]::SetCurrentProcessExplicitAppUserModelID($script:AppUserModelId)
}
catch {
    Write-Verbose "AppUserModelID could not be set: $($_.Exception.Message)"
}
function Set-ConsoleWindowState {
    param([Parameter(Mandatory)][ValidateSet('restored','hidden')][string]$State)
    try {
        $handle = [PingMonitor.NativeMethods]::GetConsoleWindow()
        if ($handle -ne [IntPtr]::Zero) {
            [void][PingMonitor.NativeMethods]::ShowWindow($handle, $(if ($State -eq 'hidden') { 0 } else { 1 }))
        }
        $script:ConsoleWasHidden = $State -eq 'hidden'
    }
    catch {
        Write-Verbose "Console window could not be $State`: $($_.Exception.Message)"
    }
}
#endregion
#region 02.Theme.Base

$script:ThemeContractKeys = @(
    'Window.Background', 'Toolbar.Background', 'Divider', 'Border',
    'Card.Background', 'Card.Border',
    'Text.Primary', 'Text.Secondary', 'Text.Muted',
    'Accent', 'Accent.Hover', 'Accent.Pressed',
    'Hover.Background', 'Pressed.Background',
    'Status.Success', 'Status.Warning', 'Status.Critical', 'Status.Failure', 'Status.Neutral', 'Status.Question',
    'Brand.StatusDot',
    'Caption.Foreground', 'Caption.Hover', 'Caption.Pressed', 'Caption.CloseHover', 'Caption.ClosePressed',
    'MenuItem.IconFill', 'MenuItem.TextFill',
    'Popup.Background', 'Popup.Border',
    'MessageBox.Background', 'MessageBox.Border',
    'Scrollbar.Thumb', 'Scrollbar.ThumbHover'
)
function Test-ThemeContract {
    param([Parameter(Mandatory)][hashtable]$Colors, [Parameter(Mandatory)][string]$ThemeName)
    $missing = @($script:ThemeContractKeys | Where-Object { -not $Colors.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        throw "Theme '$ThemeName' is missing required colour keys: $($missing -join ', ')"
    }
}
function New-ThemeResourceDictionary {
    param([Parameter(Mandatory)][hashtable]$Colors)
    $dict = [System.Windows.ResourceDictionary]::new()
    foreach ($key in $Colors.Keys) {
        $brush = [System.Windows.Media.SolidColorBrush]::new($Colors[$key])
        if ($brush.CanFreeze) { $brush.Freeze() }
        $dict["Theme.$key"] = $brush
    }
    return $dict
}
$script:BaseStyleXaml = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <Style x:Key="ToolbarSeparatorStyle" TargetType="Rectangle">
        <Setter Property="Width" Value="1"/>
        <Setter Property="Height" Value="20"/>
        <Setter Property="Fill" Value="{DynamicResource Theme.Divider}"/>
        <Setter Property="Margin" Value="2,0,6,0"/>
    </Style>
    <Style x:Key="PrimaryButtonStyle" TargetType="Button">
        <Setter Property="Height" Value="32"/>
        <Setter Property="Padding" Value="10,6"/>
        <Setter Property="Margin" Value="0,0,4,0"/>
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="Foreground" Value="{DynamicResource Theme.Text.Primary}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border x:Name="Bg" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4" Padding="{TemplateBinding Padding}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" TextElement.Foreground="{TemplateBinding Foreground}"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bg" Property="Background" Value="{DynamicResource Theme.Hover.Background}"/>
                            <Setter TargetName="Bg" Property="BorderBrush" Value="{DynamicResource Theme.Accent}"/>
                            <Setter Property="Foreground" Value="{DynamicResource Theme.Accent}"/>
                        </Trigger>
                        <Trigger Property="IsPressed" Value="True">
                            <Setter TargetName="Bg" Property="Background" Value="{DynamicResource Theme.Pressed.Background}"/>
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter Property="Opacity" Value="0.5"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        <Style.Resources>
            <Style TargetType="Path">
                <Setter Property="Fill" Value="{DynamicResource Theme.Text.Secondary}"/>
                <Style.Triggers>
                    <DataTrigger Binding="{Binding RelativeSource={RelativeSource AncestorType={x:Type Button}}, Path=IsMouseOver}" Value="True">
                        <Setter Property="Fill" Value="{DynamicResource Theme.Accent}"/>
                    </DataTrigger>
                </Style.Triggers>
            </Style>
            <Style TargetType="TextBlock">
                <Setter Property="Foreground" Value="{DynamicResource Theme.Text.Primary}"/>
                <Style.Triggers>
                    <DataTrigger Binding="{Binding RelativeSource={RelativeSource AncestorType={x:Type Button}}, Path=IsMouseOver}" Value="True">
                        <Setter Property="Foreground" Value="{DynamicResource Theme.Accent}"/>
                    </DataTrigger>
                </Style.Triggers>
            </Style>
        </Style.Resources>
    </Style>
    <Style x:Key="ActionButtonStyle" TargetType="Button">
        <Setter Property="Height" Value="32"/>
        <Setter Property="MinWidth" Value="80"/>
        <Setter Property="Padding" Value="14,1"/>
        <Setter Property="Background" Value="{DynamicResource Theme.Accent}"/>
        <Setter Property="Foreground" Value="White"/>
        <Setter Property="BorderThickness" Value="0"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="FontWeight" Value="SemiBold"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border x:Name="Bg" Background="{TemplateBinding Background}" CornerRadius="4" BorderThickness="{TemplateBinding BorderThickness}" BorderBrush="{TemplateBinding BorderBrush}" Padding="{TemplateBinding Padding}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" TextElement.Foreground="{TemplateBinding Foreground}"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bg" Property="Background" Value="{DynamicResource Theme.Accent.Hover}"/>
                        </Trigger>
                        <Trigger Property="IsPressed" Value="True">
                            <Setter TargetName="Bg" Property="Background" Value="{DynamicResource Theme.Accent.Pressed}"/>
                        </Trigger>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter Property="Opacity" Value="0.6"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style TargetType="Button" BasedOn="{StaticResource PrimaryButtonStyle}"/>
    <Style x:Key="IconButtonStyle" TargetType="Button">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="BorderThickness" Value="0"/>
        <Setter Property="Foreground" Value="{DynamicResource Theme.Text.Secondary}"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style x:Key="SplitButtonPartStyle" TargetType="Button">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="BorderThickness" Value="0"/>
        <Setter Property="Foreground" Value="{DynamicResource Theme.Text.Secondary}"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border x:Name="PartBorder" Background="{TemplateBinding Background}" CornerRadius="3">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="PartBorder" Property="Background" Value="{DynamicResource Theme.Hover.Background}"/>
                        </Trigger>
                        <Trigger Property="IsPressed" Value="True">
                            <Setter TargetName="PartBorder" Property="Background" Value="{DynamicResource Theme.Pressed.Background}"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        <Style.Resources>
            <Style TargetType="Path">
                <Setter Property="Fill" Value="{DynamicResource Theme.Text.Secondary}"/>
                <Style.Triggers>
                    <DataTrigger Binding="{Binding RelativeSource={RelativeSource AncestorType={x:Type Button}}, Path=IsMouseOver}" Value="True">
                        <Setter Property="Fill" Value="{DynamicResource Theme.Accent}"/>
                    </DataTrigger>
                </Style.Triggers>
            </Style>
            <Style TargetType="TextBlock">
                <Setter Property="Foreground" Value="{DynamicResource Theme.Text.Primary}"/>
                <Style.Triggers>
                    <DataTrigger Binding="{Binding RelativeSource={RelativeSource AncestorType={x:Type Button}}, Path=IsMouseOver}" Value="True">
                        <Setter Property="Foreground" Value="{DynamicResource Theme.Accent}"/>
                    </DataTrigger>
                </Style.Triggers>
            </Style>
        </Style.Resources>
    </Style>
    <Style x:Key="SplitMenuButtonStyle" TargetType="Button">
        <Setter Property="Height" Value="30"/>
        <Setter Property="HorizontalAlignment" Value="Stretch"/>
        <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
        <Setter Property="VerticalContentAlignment" Value="Center"/>
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="Foreground" Value="{DynamicResource Theme.MenuItem.TextFill}"/>
        <Setter Property="FontSize" Value="13"/>
        <Setter Property="BorderThickness" Value="0"/>
        <Setter Property="Padding" Value="6,0"/>
        <Setter Property="Margin" Value="0"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border x:Name="MenuBorder" Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
                        <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="MenuBorder" Property="Background" Value="{DynamicResource Theme.Hover.Background}"/>
                        </Trigger>
                        <Trigger Property="IsPressed" Value="True">
                            <Setter TargetName="MenuBorder" Property="Background" Value="{DynamicResource Theme.Pressed.Background}"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="CaptionButtonStyle" TargetType="Button">
        <Setter Property="Width" Value="46"/>
        <Setter Property="Height" Value="32"/>
        <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
        <Setter Property="FontSize" Value="10"/>
        <Setter Property="Foreground" Value="{DynamicResource Theme.Caption.Foreground}"/>
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="BorderThickness" Value="0"/>
        <Setter Property="Focusable" Value="False"/>
        <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border Background="{TemplateBinding Background}" CornerRadius="6" SnapsToDevicePixels="True">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="{DynamicResource Theme.Caption.Hover}"/>
            </Trigger>
            <Trigger Property="IsPressed" Value="True">
                <Setter Property="Background" Value="{DynamicResource Theme.Caption.Pressed}"/>
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="CaptionCloseButtonStyle" TargetType="Button" BasedOn="{StaticResource CaptionButtonStyle}">
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="{DynamicResource Theme.Caption.CloseHover}"/>
                <Setter Property="Foreground" Value="White"/>
            </Trigger>
            <Trigger Property="IsPressed" Value="True">
                <Setter Property="Background" Value="{DynamicResource Theme.Caption.ClosePressed}"/>
                <Setter Property="Foreground" Value="White"/>
            </Trigger>
        </Style.Triggers>
    </Style>
    <!-- Shared theme for every context menu in the application. Uses the standard WPF menu template. -->
    <Style x:Key="ThemedContextMenuStyle" TargetType="ContextMenu">
        <Setter Property="Background" Value="{DynamicResource Theme.Popup.Background}"/>
        <Setter Property="Foreground" Value="{DynamicResource Theme.MenuItem.TextFill}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource Theme.Popup.Border}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="Padding" Value="3"/>
        <Setter Property="SnapsToDevicePixels" Value="True"/>
    </Style>
    <Style x:Key="ThemedContextMenuItemStyle" TargetType="MenuItem">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="Foreground" Value="{DynamicResource Theme.MenuItem.TextFill}"/>
        <Setter Property="Padding" Value="6,5"/>
        <Setter Property="MinHeight" Value="30"/>
        <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
        <Setter Property="VerticalContentAlignment" Value="Center"/>
        <Setter Property="SnapsToDevicePixels" Value="True"/>
    </Style>
    <Style TargetType="ContextMenu" BasedOn="{StaticResource ThemedContextMenuStyle}"/>
    <Style TargetType="MenuItem" BasedOn="{StaticResource ThemedContextMenuItemStyle}"/>
    <Style x:Key="ThemedScrollBarThumb" TargetType="Thumb">
        <Setter Property="Background" Value="{DynamicResource Theme.Scrollbar.Thumb}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Thumb">
                    <Border Background="{TemplateBinding Background}" CornerRadius="4" Margin="2"/>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="{DynamicResource Theme.Scrollbar.ThumbHover}"/>
            </Trigger>
            <Trigger Property="IsDragging" Value="True">
                <Setter Property="Background" Value="{DynamicResource Theme.Scrollbar.ThumbHover}"/>
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style TargetType="ScrollBar">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="Width" Value="10"/>
        <Setter Property="MinWidth" Value="10"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ScrollBar">
                    <Grid Background="{TemplateBinding Background}">
                        <Track x:Name="PART_Track" IsDirectionReversed="True" Focusable="False">
                            <Track.Thumb>
                                <Thumb Style="{StaticResource ThemedScrollBarThumb}"/>
                            </Track.Thumb>
                            <Track.DecreaseRepeatButton>
                                <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Opacity="0" Focusable="False"/>
                            </Track.DecreaseRepeatButton>
                            <Track.IncreaseRepeatButton>
                                <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Opacity="0" Focusable="False"/>
                            </Track.IncreaseRepeatButton>
                        </Track>
                    </Grid>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        <Style.Triggers>
            <Trigger Property="Orientation" Value="Horizontal">
                <Setter Property="Height" Value="10"/>
                <Setter Property="MinHeight" Value="10"/>
                <Setter Property="Width" Value="Auto"/>
                <Setter Property="MinWidth" Value="0"/>
                <Setter Property="Template">
                    <Setter.Value>
                        <ControlTemplate TargetType="ScrollBar">
                            <Grid Background="{TemplateBinding Background}">
                                <Track x:Name="PART_Track" IsDirectionReversed="False" Focusable="False">
                                    <Track.Thumb>
                                        <Thumb Style="{StaticResource ThemedScrollBarThumb}"/>
                                    </Track.Thumb>
                                    <Track.DecreaseRepeatButton>
                                        <RepeatButton Command="{x:Static ScrollBar.PageLeftCommand}" Opacity="0" Focusable="False"/>
                                    </Track.DecreaseRepeatButton>
                                    <Track.IncreaseRepeatButton>
                                        <RepeatButton Command="{x:Static ScrollBar.PageRightCommand}" Opacity="0" Focusable="False"/>
                                    </Track.IncreaseRepeatButton>
                                </Track>
                            </Grid>
                        </ControlTemplate>
                    </Setter.Value>
                </Setter>
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style TargetType="TextBox">
        <Setter Property="Height" Value="30"/>
        <Setter Property="MinWidth" Value="120"/>
        <Setter Property="Padding" Value="8,4"/>
        <Setter Property="VerticalContentAlignment" Value="Center"/>
        <Setter Property="Background" Value="{DynamicResource Theme.Card.Background}"/>
        <Setter Property="Foreground" Value="{DynamicResource Theme.Text.Primary}"/>
        <Setter Property="CaretBrush" Value="{DynamicResource Theme.Text.Primary}"/>
        <Setter Property="SelectionBrush" Value="{DynamicResource Theme.Accent}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    </Style>
    <DropShadowEffect x:Key="Theme.ControlShadow" BlurRadius="8" ShadowDepth="1" Opacity="0.16"/>
    <Style x:Key="ThemedComboBoxItemStyle" TargetType="ComboBoxItem">
        <Setter Property="Padding" Value="8,6"/>
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="Foreground" Value="{DynamicResource Theme.MenuItem.TextFill}"/>
        <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ComboBoxItem">
                    <Border x:Name="Bg" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" HorizontalAlignment="Stretch" SnapsToDevicePixels="True">
                        <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" TextElement.Foreground="{TemplateBinding Foreground}"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsHighlighted" Value="True">
                            <Setter TargetName="Bg" Property="Background" Value="{DynamicResource Theme.Hover.Background}"/>
                        </Trigger>
                        <Trigger Property="IsSelected" Value="True">
                            <Setter TargetName="Bg" Property="Background" Value="{DynamicResource Theme.Pressed.Background}"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style TargetType="ComboBox">
        <Setter Property="Height" Value="30"/>
        <Setter Property="Padding" Value="8,4"/>
        <Setter Property="Background" Value="{DynamicResource Theme.Card.Background}"/>
        <Setter Property="Foreground" Value="{DynamicResource Theme.Text.Primary}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="ItemContainerStyle" Value="{StaticResource ThemedComboBoxItemStyle}"/>
        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="ComboBox">
                    <Grid>
                        <ToggleButton x:Name="Toggle" Focusable="False" ClickMode="Press" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                            <ToggleButton.Template>
                                <ControlTemplate TargetType="ToggleButton">
                                    <Border x:Name="ToggleBg" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
                                        <Grid>
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="22"/>
                                            </Grid.ColumnDefinitions>
                                            <Path Grid.Column="1" Width="8" Height="5" Stretch="Fill" Fill="{DynamicResource Theme.Text.Secondary}" HorizontalAlignment="Center" VerticalAlignment="Center" Data="M0,0 L8,0 L4,5 Z"/>
                                        </Grid>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="ToggleBg" Property="BorderBrush" Value="{DynamicResource Theme.Accent}"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </ToggleButton.Template>
                        </ToggleButton>
                        <ContentPresenter x:Name="ContentSite" IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" TextElement.Foreground="{TemplateBinding Foreground}" Margin="{TemplateBinding Padding}" HorizontalAlignment="Left" VerticalAlignment="Center"/>
                        <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Width="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MinWidth="120" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="None" StaysOpen="False">
                            <Border Background="{DynamicResource Theme.Window.Background}" BorderBrush="{DynamicResource Theme.Popup.Border}" BorderThickness="1" CornerRadius="4" Padding="2" HorizontalAlignment="Stretch">
                                <Border.Effect>
                                    <DropShadowEffect BlurRadius="14" ShadowDepth="3" Opacity="0.20"/>
                                </Border.Effect>
                                <ScrollViewer MaxHeight="200" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                    <ItemsPresenter/>
                                </ScrollViewer>
                            </Border>
                        </Popup>
                    </Grid>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
</ResourceDictionary>
'@
function New-AppResources {
    param([Parameter(Mandatory)][hashtable]$Colors, [Parameter(Mandatory)][string]$ThemeName)
    Test-ThemeContract -Colors $Colors -ThemeName $ThemeName
    $reader = [System.Xml.XmlNodeReader]::new([xml]$script:BaseStyleXaml)
    try {
        $baseDict = [System.Windows.Markup.XamlReader]::Load($reader)
        $baseDict.MergedDictionaries.Add((New-ThemeResourceDictionary -Colors $Colors))
        return $baseDict
    }
    finally {
        $reader.Dispose()
    }
}
function Set-AppTheme {
    param([Parameter(Mandatory)][ValidateSet('Light', 'Dark', 'System')][string]$ThemeName)
    if (-not $script:ThemeRegistry.Contains($ThemeName)) { return $false }
    $effectiveTheme = if ($ThemeName -eq 'System') { Get-SystemThemeName } else { $ThemeName }
    $colors = & $script:ThemeRegistry[$ThemeName]
    Test-ThemeContract -Colors $colors -ThemeName $effectiveTheme
    $colorDict = $script:AppResources.MergedDictionaries | Where-Object { $_.Contains('Theme.Window.Background') } | Select-Object -First 1
    if (-not $colorDict) { return $false }
    foreach ($key in $colors.Keys) {
        $brush = [System.Windows.Media.SolidColorBrush]::new($colors[$key])
        if ($brush.CanFreeze) { $brush.Freeze() }
        $colorDict["Theme.$key"] = $brush
    }
    $script:ThemeName = $ThemeName
    $script:ThemeColors = $colors
    $script:EffectiveThemeName = $effectiveTheme
    if ($Window -and $Window.IsInitialized) {
        $Window.Icon = New-AppIconSource
    }
    if ($script:OptionsDialog -and $script:OptionsDialog.IsInitialized) {
        $script:OptionsDialog.Icon = New-AppIconSource
    }
    return $true
}
function Register-SystemThemeWatcher {
    if ($script:SystemThemeWatcher -or -not $Window) { return }
    $script:SystemThemeWatcher = [Microsoft.Win32.UserPreferenceChangedEventHandler]{
        param($sender, $e)
        if ($script:ThemeName -ne 'System' -or -not $Window) { return }
        $Window.Dispatcher.BeginInvoke([Action]{
            $effectiveTheme = Get-SystemThemeName
            if ($effectiveTheme -ne $script:EffectiveThemeName) { [void](Set-AppTheme -ThemeName 'System') }
        }) | Out-Null
    }
    [Microsoft.Win32.SystemEvents]::add_UserPreferenceChanged($script:SystemThemeWatcher)
}
function Unregister-SystemThemeWatcher {
    if (-not $script:SystemThemeWatcher) { return }
    [Microsoft.Win32.SystemEvents]::remove_UserPreferenceChanged($script:SystemThemeWatcher)
    $script:SystemThemeWatcher = $null
}
function Get-LightThemeColors {
    $c = [System.Windows.Media.Color]
    @{
        'Window.Background'   = $c::FromRgb(0xF3, 0xF6, 0xFA)
        'Toolbar.Background'  = $c::FromRgb(0xFF, 0xFF, 0xFF)
        'Divider'             = $c::FromRgb(0xE3, 0xE7, 0xEC)
        'Border'              = $c::FromRgb(0xD9, 0xE0, 0xE8)
        'Card.Background'     = $c::FromRgb(0xFF, 0xFF, 0xFF)
        'Card.Border'         = $c::FromRgb(0xE2, 0xE8, 0xF0)
        'Text.Primary'        = $c::FromRgb(0x1F, 0x29, 0x37)
        'Text.Secondary'      = $c::FromRgb(0x64, 0x74, 0x8B)
        'Text.Muted'          = $c::FromRgb(0x94, 0xA3, 0xB8)
        'Accent'              = $c::FromRgb(0x25, 0x63, 0xEB)
        'Accent.Hover'        = $c::FromRgb(0x1D, 0x4E, 0xD8)
        'Accent.Pressed'      = $c::FromRgb(0x1E, 0x40, 0xAF)
        'Hover.Background'    = $c::FromRgb(0xF0, 0xF4, 0xF8)
        'Pressed.Background'  = $c::FromRgb(0xE2, 0xE8, 0xF0)
        'Status.Success'      = $c::FromRgb(0x10, 0xB9, 0x81)
        'Status.Warning'      = $c::FromRgb(0xF5, 0x9E, 0x0B)
        'Status.Critical'     = $c::FromRgb(0xDC, 0x26, 0x26)
        'Status.Failure'      = $c::FromRgb(0xEF, 0x44, 0x44)
        'Status.Neutral'      = $c::FromRgb(0x94, 0xA3, 0xB8)
        'Status.Question'     = $c::FromRgb(0x7C, 0x3A, 0xED)
        'Brand.StatusDot'     = $c::FromRgb(0x22, 0xC5, 0x5E)
        'Caption.Foreground'  = $c::FromRgb(0x1F, 0x29, 0x37)
        'Caption.Hover'       = $c::FromRgb(0xE5, 0xE5, 0xE5)
        'Caption.Pressed'     = $c::FromRgb(0xCC, 0xCC, 0xCC)
        'Caption.CloseHover'  = $c::FromRgb(0xC4, 0x2B, 0x1C)
        'Caption.ClosePressed'= $c::FromRgb(0xB3, 0x2A, 0x1C)
        'MenuItem.IconFill'   = $c::FromRgb(0x47, 0x55, 0x69)
        'MenuItem.TextFill'   = $c::FromRgb(0x1F, 0x29, 0x37)
        'Popup.Background'    = $c::FromRgb(0xFF, 0xFF, 0xFF)
        'Popup.Border'        = $c::FromRgb(0xD9, 0xE0, 0xE8)
        'MessageBox.Background'= $c::FromRgb(0xFF, 0xFF, 0xFF)
        'MessageBox.Border'   = $c::FromRgb(0x9C, 0xA3, 0xAF)
        'Scrollbar.Thumb'     = $c::FromRgb(0xC7, 0xCE, 0xD8)
        'Scrollbar.ThumbHover'= $c::FromRgb(0xA8, 0xB3, 0xC2)
    }
}
#endregion
#region 04.Theme.Dark

function Get-DarkThemeColors {
    $c = [System.Windows.Media.Color]
    @{
        'Window.Background'   = $c::FromRgb(0x15, 0x1A, 0x21)
        'Toolbar.Background'  = $c::FromRgb(0x1E, 0x25, 0x2E)
        'Divider'             = $c::FromRgb(0x2E, 0x37, 0x42)
        'Border'              = $c::FromRgb(0x33, 0x3D, 0x49)
        'Card.Background'     = $c::FromRgb(0x1E, 0x25, 0x2E)
        'Card.Border'         = $c::FromRgb(0x2E, 0x37, 0x42)
        'Text.Primary'        = $c::FromRgb(0xE5, 0xE9, 0xF0)
        'Text.Secondary'      = $c::FromRgb(0x9C, 0xA7, 0xB4)
        'Text.Muted'          = $c::FromRgb(0x6B, 0x76, 0x84)
        'Accent'              = $c::FromRgb(0x3B, 0x82, 0xF6)
        'Accent.Hover'        = $c::FromRgb(0x60, 0xA5, 0xFA)
        'Accent.Pressed'      = $c::FromRgb(0x25, 0x63, 0xEB)
        'Hover.Background'    = $c::FromRgb(0x27, 0x30, 0x3B)
        'Pressed.Background'  = $c::FromRgb(0x30, 0x3A, 0x46)
        'Status.Success'      = $c::FromRgb(0x34, 0xD3, 0x99)
        'Status.Warning'      = $c::FromRgb(0xFB, 0xBF, 0x24)
        'Status.Critical'     = $c::FromRgb(0xF8, 0x71, 0x71)
        'Status.Failure'      = $c::FromRgb(0xF8, 0x71, 0x71)
        'Status.Neutral'      = $c::FromRgb(0x6B, 0x76, 0x84)
        'Status.Question'     = $c::FromRgb(0xA1, 0x8A, 0xFA)
        'Brand.StatusDot'     = $c::FromRgb(0x4A, 0xDE, 0x80)
        'Caption.Foreground'  = $c::FromRgb(0xE5, 0xE9, 0xF0)
        'Caption.Hover'       = $c::FromRgb(0x33, 0x3D, 0x49)
        'Caption.Pressed'     = $c::FromRgb(0x3F, 0x4A, 0x58)
        'Caption.CloseHover'  = $c::FromRgb(0xC4, 0x2B, 0x1C)
        'Caption.ClosePressed'= $c::FromRgb(0xB3, 0x2A, 0x1C)
        'MenuItem.IconFill'   = $c::FromRgb(0xB0, 0xBA, 0xC6)
        'MenuItem.TextFill'   = $c::FromRgb(0xE5, 0xE9, 0xF0)
        'Popup.Background'    = $c::FromRgb(0x1E, 0x25, 0x2E)
        'Popup.Border'        = $c::FromRgb(0x33, 0x3D, 0x49)
        'MessageBox.Background'= $c::FromRgb(0x2E, 0x39, 0x47)
        'MessageBox.Border'   = $c::FromRgb(0x6B, 0x76, 0x84)
        'Scrollbar.Thumb'     = $c::FromRgb(0x45, 0x50, 0x5D)
        'Scrollbar.ThumbHover'= $c::FromRgb(0x5A, 0x66, 0x74)
    }
}
function Get-SystemThemeName {
    try {
        $value = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
        if ([int]$value -eq 0) { return 'Dark' }
        return 'Light'
    }
    catch { return 'Light' }
}
$script:ThemeRegistry = [ordered]@{
    'Light'  = { Get-LightThemeColors }
    'Dark'   = { Get-DarkThemeColors }
    'System' = { if ((Get-SystemThemeName) -eq 'Dark') { Get-DarkThemeColors } else { Get-LightThemeColors } }
}
#endregion
#region 10.Views.Common

function Read-XamlWindow {
    [cmdletbinding()]
    param(
        [Parameter(Mandatory)][xml]$Xaml,
        [System.Windows.ResourceDictionary]$ResourceDict
    )
    try {
        $reader = [System.Xml.XmlNodeReader]::new($Xaml)
        $element = [System.Windows.Markup.XamlReader]::Load($reader)
        if ($ResourceDict) {
            $element.Resources.MergedDictionaries.Add($ResourceDict)
        }
        return $element
    }
    catch {
        throw
    }
    finally {
        $reader.Dispose()
    }
}
function Get-ThemeBrush {
    param([Parameter(Mandatory)][string]$Key)
    [System.Windows.Media.SolidColorBrush]::new($script:ThemeColors[$Key])
}
$script:AppLogoXaml = [xml]@'
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="48" Height="48">
    <Ellipse Canvas.Left="4.5" Canvas.Top="4.5" Width="39" Height="39" Stroke="{DynamicResource Theme.Accent}" StrokeThickness="3.75" Fill="{DynamicResource Theme.Card.Background}"/>
    <Path Data="M10.5 24 H16.5 L21 13.5 L25.5 34.5 L30 24 H37.5" Stroke="{DynamicResource Theme.Accent}" StrokeThickness="3.75" StrokeDashCap="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
    <Ellipse Canvas.Left="34.5" Canvas.Top="18.8" Width="10.5" Height="10.5" Fill="{DynamicResource Theme.Brand.StatusDot}" Stroke="{DynamicResource Theme.Accent}"/>
</Canvas>
'@
function New-AppLogoVisual {
    Read-XamlWindow -Xaml $script:AppLogoXaml -ResourceDict $script:AppResources
}
function New-AppIconSource {
    $visual = New-AppLogoVisual
    $size = 48
    $visual.Measure([System.Windows.Size]::new($size, $size))
    $visual.Arrange([System.Windows.Rect]::new(0, 0, $size, $size))
    $visual.UpdateLayout()
    $dpi = 96.0
    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($size, $size, $dpi, $dpi, 'Pbgra32')
    $rtb.Render($visual)
    return [System.Windows.Media.Imaging.BitmapFrame]::Create([System.Windows.Media.Imaging.BitmapSource]$rtb)
}
$script:MessageBoxXaml = [xml]@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" WindowStartupLocation="CenterOwner" WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="False" SizeToContent="WidthAndHeight" Background="Transparent" AllowsTransparency="True" FocusManager.FocusedElement="{Binding ElementName=OKButton}">
    <Border Background="{DynamicResource Theme.MessageBox.Background}" BorderBrush="{DynamicResource Theme.MessageBox.Border}"
        BorderThickness="1" CornerRadius="12" Padding="24" Margin="10">
        <Border.Effect>
            <DropShadowEffect Color="#000000" BlurRadius="14" ShadowDepth="4" Opacity="0.12" />
        </Border.Effect>
        <StackPanel Width="400">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Top" Margin="0,0,0,14">
                <TextBlock Name="MessageIcon" Text="&#xE946;" FontFamily="Segoe MDL2 Assets" FontSize="28" Margin="0,0,15,0" />
                <TextBlock Name="TitleTxt" FontSize="16" FontWeight="SemiBold" Foreground="{DynamicResource Theme.Text.Primary}" Margin="0,0,0,12" />
            </StackPanel>
            <TextBlock Name="MessageTxt" FontSize="14" Foreground="{DynamicResource Theme.Text.Secondary}" TextWrapping="Wrap" Margin="44,0,0,0"/>
            <Button Name="OKButton" Content="OK" Height="34" HorizontalAlignment="Right" Margin="0,20,0,0" Background="{DynamicResource Theme.Accent}" Foreground="White" BorderThickness="0" FontWeight="SemiBold" IsDefault="True" IsCancel="True" Style="{DynamicResource ActionButtonStyle}"/>
        </StackPanel>
    </Border>
</Window>
'@
$script:MessageBoxIconMap = @{
    Information = @{ Glyph = [char]0xE946; ColorKey = 'Accent' }
    Warning     = @{ Glyph = [char]0xE7BA; ColorKey = 'Status.Warning' }
    Error       = @{ Glyph = [char]0xE783; ColorKey = 'Status.Critical' }
    Question    = @{ Glyph = [char]0xE9CE; ColorKey = 'Status.Question' }
}
function Show-MessageBox {
    param(
        [string]$Message,
        [string]$Title = 'Message',
        [ValidateSet('Information', 'Warning', 'Error', 'Question')][string]$Icon = 'Information'
    )
    $iconInfo = $script:MessageBoxIconMap[$Icon]
    $dialog = Read-XamlWindow -Xaml $script:MessageBoxXaml -ResourceDict $script:AppResources
    $dialog.Owner = $Window
    $dialog.FindName('TitleTxt').Text = $Title
    $iconText = $dialog.FindName('MessageIcon')
    $iconText.Text = $iconInfo.Glyph
    $iconText.Foreground = Get-ThemeBrush -Key $iconInfo.ColorKey
    $dialog.FindName('MessageTxt').Text = $Message
    $dialog.FindName('OKButton').Add_Click({ $dialog.Close() })
    $dialog.Add_KeyDown({
            param($sender, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Escape -or $e.Key -eq [System.Windows.Input.Key]::Enter) {
                $sender.Close()
            }
        })
    if ($ModalOverlay) { $ModalOverlay.Visibility = 'Visible' }
    try { [void]$dialog.ShowDialog() }
    finally { if ($ModalOverlay) { $ModalOverlay.Visibility = 'Collapsed' } }
}
#endregion
#region 11.Views.MainWindow

$script:MainWindowXaml = [xml]@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" x:Name="RootWindow" Title="PingMonitor" Width="532" Height="500" MinWidth="258" MinHeight="320" WindowStartupLocation="CenterScreen" WindowStyle="None" Background="{DynamicResource Theme.Window.Background}" FontFamily="Segoe UI" FontSize="13" SnapsToDevicePixels="True">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="32"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Border x:Name="TitleBar" Grid.Row="0" Height="32" Background="{DynamicResource Theme.Toolbar.Background}" BorderBrush="{DynamicResource Theme.Divider}" BorderThickness="0,0,0,1">
            <DockPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                    <Button x:Name="ModeToggleButton" Content="&#xE70E;" ToolTip="Compact mode (F9)" Style="{DynamicResource CaptionButtonStyle}"/>
                    <Button x:Name="TitleMinimizeButton" Content="&#xE921;" ToolTip="Minimize" Style="{DynamicResource CaptionButtonStyle}"/>
                    <Button x:Name="TitleMaximizeButton" Content="&#xE922;" ToolTip="Maximize" Style="{DynamicResource CaptionButtonStyle}"/>
                    <Button x:Name="TitleCloseButton" Content="&#xE8BB;" ToolTip="Close" Style="{DynamicResource CaptionCloseButtonStyle}"/>
                </StackPanel>
                <Viewbox x:Name="TitleLogoBox" Width="16" Height="16" Margin="10,0,8,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
                <TextBlock Text="PingMonitor" VerticalAlignment="Center" FontSize="12" Foreground="{DynamicResource Theme.Caption.Foreground}"/>
            </DockPanel>
        </Border>
        <Border x:Name="ToolbarPanel" Grid.Row="1" Background="{DynamicResource Theme.Toolbar.Background}" BorderBrush="{DynamicResource Theme.Divider}" BorderThickness="0,0,0,1" Padding="1,8">
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="PM" FontSize="18" FontWeight="SemiBold" Foreground="{DynamicResource Theme.Accent}" VerticalAlignment="Center" Margin="13,0,8,0"/>
                    <Button x:Name="LoadButton" Style="{DynamicResource PrimaryButtonStyle}" ToolTip="Load configuration (F2)">
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                            <Path Data="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z" Width="16" Height="16" Stretch="Uniform" SnapsToDevicePixels="True"/>
                            <TextBlock Text="Load" VerticalAlignment="Center" Margin="6,0,0,0"/>
                        </StackPanel>
                    </Button>
                    <Button x:Name="SaveButton" Style="{DynamicResource PrimaryButtonStyle}" ToolTip="Save configuration (F3 / Ctrl+S)">
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                            <Path Data="M17 3H5c-1.11 0-2 .9-2 2v14c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V7l-4-4zm-5 16c-1.66 0-3-1.34-3-3s1.34-3 3-3 3 1.34 3 3-1.34 3-3 3zm3-10H5V5h10v4z" Width="16" Height="16" Stretch="Uniform" SnapsToDevicePixels="True"/>
                            <TextBlock Text="Save" VerticalAlignment="Center" Margin="6,0,0,0"/>
                        </StackPanel>
                    </Button>
                    <Rectangle Style="{DynamicResource ToolbarSeparatorStyle}"/>
                    <Border x:Name="GlobalActionSplitButton" Height="32" Margin="0,0,4,0" BorderThickness="1" CornerRadius="4" SnapsToDevicePixels="True">
                        <Border.Style>
                            <Style TargetType="Border">
                                <Setter Property="Background" Value="Transparent"/>
                                <Setter Property="BorderBrush" Value="{DynamicResource Theme.Border}"/>
                                <Style.Triggers>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter Property="Background" Value="{DynamicResource Theme.Hover.Background}"/>
                                        <Setter Property="BorderBrush" Value="{DynamicResource Theme.Accent}"/>
                                    </Trigger>
                                </Style.Triggers>
                            </Style>
                        </Border.Style>
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="1"/>
                                <ColumnDefinition Width="12"/>
                            </Grid.ColumnDefinitions>
                            <Button x:Name="GlobalActionButton" Grid.Column="0" Style="{DynamicResource SplitButtonPartStyle}" Padding="10,6">
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                                    <Path x:Name="GlobalActionIcon" Width="14" Height="14" Stretch="Uniform" Margin="6,0,0,0" SnapsToDevicePixels="True"/>
                                    <TextBlock x:Name="GlobalActionText" Text="Clear" VerticalAlignment="Center" Margin="4,0,4,0"/>
                                </StackPanel>
                            </Button>
                            <Border Grid.Column="1" Width="1" Height="18" VerticalAlignment="Center" Background="{DynamicResource Theme.Border}"/>
                            <Button x:Name="GlobalActionArrowButton" Grid.Column="2" Style="{DynamicResource SplitButtonPartStyle}" Padding="0" ToolTip="More actions">
                                <Path Width="6" Height="5" Stretch="Fill" Margin="0,2,3,0" Data="M0,0 L8,0 L4,5 Z"/>
                            </Button>
                        </Grid>
                    </Border>
                    <Button x:Name="ViewToggleButton" Style="{DynamicResource PrimaryButtonStyle}" ToolTip="Switch to table view">
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                            <Path x:Name="ViewToggleIcon" Width="16" Height="16" Stretch="Uniform" Data="M3,3H21V21H3V3M5,5V8H19V5H5M5,10V14H19V10H5M5,16V19H19V16H5Z" SnapsToDevicePixels="True"/>
                            <TextBlock x:Name="ViewToggleText" Text="Table" VerticalAlignment="Center" Margin="6,0,0,0"/>
                        </StackPanel>
                    </Button>
                    <Button x:Name="OptionsButton" Style="{DynamicResource PrimaryButtonStyle}" ToolTip="Monitoring options (Ctrl+,)">
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                            <Path Data="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z" Width="16" Height="16" Stretch="Uniform" SnapsToDevicePixels="True"/>
                            <TextBlock Text="Options" VerticalAlignment="Center" Margin="6,0,0,0"/>
                        </StackPanel>
                    </Button>
                </StackPanel>
            </Border>
        <Border x:Name="HostInputPanel" Grid.Row="2" Margin="6,3,6,2" Background="{DynamicResource Theme.Card.Background}" BorderBrush="{DynamicResource Theme.Border}" BorderThickness="1" CornerRadius="7" Padding="4">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Grid>
                    <TextBox x:Name="HostInput" Height="32" Padding="6,6" BorderThickness="0" Background="Transparent" Foreground="{DynamicResource Theme.Text.Primary}" VerticalContentAlignment="Center" FontSize="14" MaxLength="253"/>
                    <TextBlock x:Name="InputHint" Text="Hostname or IP address" Foreground="{DynamicResource Theme.Text.Muted}" Margin="7,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
                </Grid>
                <Button x:Name="AddButton" Grid.Column="1" Content="Add monitor" MinWidth="80" Padding="10,1" IsDefault="True" Style="{DynamicResource ActionButtonStyle}"/>
            </Grid>
        </Border>
        <Grid x:Name="ContentGrid" Grid.Row="3">
            <Viewbox Name="LogoViewBox" Stretch="Uniform" VerticalAlignment="Center" HorizontalAlignment="Center" Opacity="0.15" IsHitTestVisible="False"/>
            <Grid x:Name="CardViewContainer">
                <ScrollViewer x:Name="MonitorScroll" Margin="2" VerticalScrollBarVisibility="Visible" HorizontalScrollBarVisibility="Disabled">
                    <WrapPanel x:Name="MonitorPanel" HorizontalAlignment="Left" Background="Transparent" AllowDrop="True"/>
                </ScrollViewer>
                <Canvas x:Name="DropIndicatorOverlay" Background="Transparent" IsHitTestVisible="False"/>
            </Grid>
            <Grid x:Name="TableViewContainer" Visibility="Collapsed" Background="Transparent">
                <DataGrid x:Name="TableGrid" AutoGenerateColumns="False" IsReadOnly="True"
                    CanUserAddRows="False" CanUserDeleteRows="False" CanUserReorderColumns="True"
                    CanUserResizeColumns="True" CanUserSortColumns="False" HeadersVisibility="Column"
                    RowHeaderWidth="0" GridLinesVisibility="None" SelectionMode="Single"
                    SelectionUnit="FullRow" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto"
                    Background="Transparent" Foreground="{DynamicResource Theme.Text.Primary}"
                    BorderThickness="0" RowHeight="32" ColumnHeaderHeight="32" AllowDrop="True"
                    SnapsToDevicePixels="True" UseLayoutRounding="True">
                    <DataGrid.Resources>
                        <Style TargetType="DataGridColumnHeader">
                            <Setter Property="Background" Value="{DynamicResource Theme.Toolbar.Background}"/>
                            <Setter Property="Foreground" Value="{DynamicResource Theme.Text.Muted}"/>
                            <Setter Property="BorderBrush" Value="{DynamicResource Theme.Divider}"/>
                            <Setter Property="BorderThickness" Value="0,0,0,1"/>
                            <Setter Property="Padding" Value="10,6"/>
                            <Setter Property="HorizontalContentAlignment" Value="Center"/>
                            <Setter Property="FontSize" Value="11"/>
                            <Setter Property="FontWeight" Value="SemiBold"/>
                        </Style>
                        <Style x:Key="LeftHeaderStyle" TargetType="DataGridColumnHeader" BasedOn="{StaticResource {x:Type DataGridColumnHeader}}">
                            <Setter Property="HorizontalContentAlignment" Value="Left"/>
                        </Style>
                        <Style TargetType="DataGridRow">
                            <Setter Property="Background" Value="{DynamicResource Theme.Card.Background}"/>
                            <Setter Property="Foreground" Value="{DynamicResource Theme.Text.Primary}"/>
                            <Setter Property="Cursor" Value="Arrow"/>
                            <Setter Property="BorderBrush" Value="{DynamicResource Theme.Divider}"/>
                            <Setter Property="BorderThickness" Value="0,0,0,1"/>
                            <Style.Triggers>
                                <Trigger Property="IsSelected" Value="True">
                                    <Setter Property="Background" Value="{DynamicResource Theme.Hover.Background}"/>
                                </Trigger>
                            </Style.Triggers>
                        </Style>
                        <Style TargetType="DataGridCell">
                            <Setter Property="BorderThickness" Value="0"/>
                            <Setter Property="Padding" Value="8,0,8,0"/>
                            <Setter Property="VerticalContentAlignment" Value="Center"/>
                            <Setter Property="HorizontalContentAlignment" Value="Center"/>
                            <Setter Property="Background" Value="Transparent"/>
                            <Setter Property="ClipToBounds" Value="True"/>
                            <Setter Property="Foreground" Value="{DynamicResource Theme.Text.Primary}"/>
                            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
                        </Style>
                    </DataGrid.Resources>
                    <DataGrid.Columns>
                        <DataGridTemplateColumn Header="Status" SortMemberPath="Status" Width="56">
                            <DataGridTemplateColumn.CellTemplate><DataTemplate>
                                <Ellipse Width="10" Height="10" Fill="{Binding StatusBrush}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </DataTemplate></DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTemplateColumn Header="Host" SortMemberPath="HostName" MinWidth="180" Width="240" HeaderStyle="{StaticResource LeftHeaderStyle}">
                            <DataGridTemplateColumn.CellTemplate><DataTemplate>
                                <TextBlock Text="{Binding HostName}" FontSize="13" Foreground="{DynamicResource Theme.Text.Primary}"
                                    TextTrimming="CharacterEllipsis" ToolTip="{Binding HostName}" Margin="8,0"
                                    HorizontalAlignment="Left" VerticalAlignment="Center"/>
                            </DataTemplate></DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTemplateColumn Header="IP" SortMemberPath="IP" Width="Auto" HeaderStyle="{StaticResource LeftHeaderStyle}">
                            <DataGridTemplateColumn.CellTemplate><DataTemplate>
                                <TextBlock Text="{Binding DisplayIp}" FontSize="12" Foreground="{DynamicResource Theme.Text.Secondary}" Margin="8,0"
                                    HorizontalAlignment="Left" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                            </DataTemplate></DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTemplateColumn Header="Latency" SortMemberPath="Latency" Width="Auto">
                            <DataGridTemplateColumn.CellTemplate><DataTemplate>
                                <TextBlock Text="{Binding DisplayLatency}" FontSize="13" FontWeight="SemiBold" Foreground="{Binding LatencyBrush}"
                                    HorizontalAlignment="Center" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                            </DataTemplate></DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTemplateColumn Header="Avg" SortMemberPath="Avg" Width="Auto">
                            <DataGridTemplateColumn.CellTemplate><DataTemplate>
                                <TextBlock Text="{Binding DisplayAvg}" FontSize="11" Foreground="{DynamicResource Theme.Text.Muted}"
                                    HorizontalAlignment="Center" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                            </DataTemplate></DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTemplateColumn Header="Min" SortMemberPath="Min" Width="Auto">
                            <DataGridTemplateColumn.CellTemplate><DataTemplate>
                                <TextBlock Text="{Binding DisplayMin}" FontSize="11" Foreground="{DynamicResource Theme.Text.Muted}"
                                    HorizontalAlignment="Center" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                            </DataTemplate></DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTemplateColumn Header="Max" SortMemberPath="Max" Width="Auto">
                            <DataGridTemplateColumn.CellTemplate><DataTemplate>
                                <TextBlock Text="{Binding DisplayMax}" FontSize="11" Foreground="{DynamicResource Theme.Text.Muted}"
                                    HorizontalAlignment="Center" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                            </DataTemplate></DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTemplateColumn Header="Drop" SortMemberPath="Drop" Width="Auto">
                            <DataGridTemplateColumn.CellTemplate><DataTemplate>
                                <TextBlock Text="{Binding DisplayDrop}" FontSize="11" Foreground="{DynamicResource Theme.Text.Muted}"
                                    HorizontalAlignment="Center" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                            </DataTemplate></DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTemplateColumn Header="History" SortMemberPath="History" Width="Auto" HeaderStyle="{StaticResource LeftHeaderStyle}">
                            <DataGridTemplateColumn.CellTemplate><DataTemplate>
                                <ItemsControl ItemsSource="{Binding HistoryDisplay}" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="8,0">
                                    <ItemsControl.ItemsPanel><ItemsPanelTemplate><StackPanel Orientation="Horizontal"/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                                    <ItemsControl.ItemTemplate><DataTemplate>
                                        <Border Width="10" Height="10" CornerRadius="2" Margin="0,0,3,0" Background="{Binding Brush}" ToolTip="{Binding ToolTip}"/>
                                    </DataTemplate></ItemsControl.ItemTemplate>
                                </ItemsControl>
                            </DataTemplate></DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                    </DataGrid.Columns>
                </DataGrid>
                <Canvas x:Name="TableDragOverlay" IsHitTestVisible="False">
                    <Border x:Name="TableDropLine" Height="3" CornerRadius="1.5" Background="{DynamicResource Theme.Accent}" Visibility="Collapsed"/>
                </Canvas>
            </Grid>
        </Grid>
        <Border x:Name="StatusBar" Grid.Row="4" Background="{DynamicResource Theme.Toolbar.Background}" BorderBrush="{DynamicResource Theme.Divider}" BorderThickness="0,1,0,0" Padding="14,7">
            <DockPanel>
                <TextBlock x:Name="StatusText" Text="Ready" Foreground="{DynamicResource Theme.Text.Secondary}"/>
                <TextBlock Text="F2 Load   F3 / Ctrl+S Save   F4 Clear   Ctrl+, Options   F8 View   F9 Compact" Foreground="{DynamicResource Theme.Text.Muted}" HorizontalAlignment="Right"/>
            </DockPanel>
        </Border>
        <Border x:Name="ModalOverlay" Grid.Row="0" Grid.RowSpan="5" Background="#99000000" Visibility="Collapsed" IsHitTestVisible="False"/>
    </Grid>
</Window>
'@
function Update-WindowMinSize {
    if (-not $Window -or -not $ContentGrid -or -not $MonitorScroll) { return }
    $Window.UpdateLayout()

    $cardWidth = [double]$script:MonitorCardFootprint.Width
    $cardHeight = [double]$script:MonitorCardFootprint.Height
    $scrollbar = [double]$script:Config.ScrollBarWidth
    if ($script:ViewMode -eq 'Table') {
        # Table is two card footprints wide and reserves both scrollbars.
        $contentWidth = (2 * $cardWidth) + $scrollbar
        $contentHeight = $cardHeight + $scrollbar
    }
    else {
        # Card view reserves only the visible vertical scrollbar.
        $contentWidth = $cardWidth + $scrollbar
        $contentHeight = $cardHeight
    }

    $root = $Window.Content
    $contentRow = [System.Windows.Controls.Grid]::GetRow($ContentGrid)
    $rowsHeight = 0.0
    for ($i = 0; $i -lt $root.RowDefinitions.Count; $i++) {
        if ($i -ne $contentRow) { $rowsHeight += $root.RowDefinitions[$i].ActualHeight }
    }

    if ([System.Windows.Shell.WindowChrome]::GetWindowChrome($Window)) {
        $frameWidth = 0.0
        $frameHeight = 0.0
    }
    else {
        $nc = [System.Windows.SystemParameters]::WindowNonClientFrameThickness
        $frameWidth = $nc.Left + $nc.Right
        $frameHeight = $nc.Top + $nc.Bottom
    }

    $Window.MinWidth = [Math]::Ceiling($contentWidth + $frameWidth)
    $Window.MinHeight = [Math]::Ceiling($contentHeight + $rowsHeight + $frameHeight)

    if ($Window.WindowState -eq 'Normal') {
        if ($Window.Width -lt $Window.MinWidth) { $Window.Width = $Window.MinWidth }
        if ($Window.Height -lt $Window.MinHeight) { $Window.Height = $Window.MinHeight }
    }
}
function Set-WindowMode {
    param([Parameter(Mandatory)][ValidateSet('Standard', 'Compact')][string]$Mode)
    if ($Mode -eq 'Compact') {
        $heightToSubtract = $ToolbarPanel.ActualHeight + $HostInputPanel.ActualHeight + $StatusBar.ActualHeight
        $script:PreCompactHeight = $Window.ActualHeight
        $ToolbarPanel.Visibility = 'Collapsed'
        $HostInputPanel.Visibility = 'Collapsed'
        $StatusBar.Visibility = 'Collapsed'
        $Window.Height = [Math]::Max($Window.MinHeight, $Window.ActualHeight - $heightToSubtract)
        $ModeToggleButton.Content = [char]0xE70D
        $ModeToggleButton.ToolTip = 'Standard mode (F9)'
        Update-WindowMinSize
    }
    else {
        $ToolbarPanel.Visibility = 'Visible'
        $HostInputPanel.Visibility = 'Visible'
        $StatusBar.Visibility = 'Visible'
        if ($script:PreCompactHeight) { $Window.Height = $script:PreCompactHeight }
        $ModeToggleButton.Content = [char]0xE70E
        $ModeToggleButton.ToolTip = 'Compact mode (F9)'
        Update-WindowMinSize
    }
    $Window.UpdateLayout()
}
function New-CustomWindowChrome {
    $chrome = [System.Windows.Shell.WindowChrome]::new()
    $chrome.CaptionHeight = 32
    $chrome.GlassFrameThickness = [System.Windows.Thickness]::new(1)
    $chrome.ResizeBorderThickness = [System.Windows.SystemParameters]::WindowResizeBorderThickness
    $chrome.UseAeroCaptionButtons = $false
    return $chrome
}
function Set-ViewMode {
    param([Parameter(Mandatory)][ValidateSet('Card', 'Table')][string]$Mode)
    $script:ViewMode = $Mode
    if ($Mode -eq 'Table') {
        $CardViewContainer.Visibility = 'Collapsed'
        $TableViewContainer.Visibility = 'Visible'
        $ViewToggleText.Text = 'Cards'
        $ViewToggleIcon.Data = [System.Windows.Media.Geometry]::Parse('M3,3H11V13H3V3M3,15H11V21H3V15M13,3H21V9H13V3M13,11H21V21H13V11Z')
        $ViewToggleButton.ToolTip = 'Switch to card view'
    }
    else {
        $TableViewContainer.Visibility = 'Collapsed'
        $CardViewContainer.Visibility = 'Visible'
        $ViewToggleText.Text = 'Table'
        $ViewToggleIcon.Data = [System.Windows.Media.Geometry]::Parse('M3,3H21V21H3V3M5,5V8H19V5H5M5,10V14H19V10H5M5,16V19H19V16H5Z')
        $ViewToggleButton.ToolTip = 'Switch to table view'
    }
    Update-WindowMinSize
}
#endregion
#region 12.Views.MonitorCard

$script:MonitorCardXaml = [xml]@'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="240" Height="160" Margin="4" Padding="0" Background="{DynamicResource Theme.Card.Background}" BorderBrush="{DynamicResource Theme.Card.Border}" BorderThickness="1" CornerRadius="10">
    <Border.Effect>
        <DropShadowEffect BlurRadius="12" ShadowDepth="2" Opacity="0.06" Color="#000000"/>
    </Border.Effect>
    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="4"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Border x:Name="StatusAccent" Grid.Column="0" Background="{DynamicResource Theme.Status.Neutral}" CornerRadius="10,0,0,10"/>
        <Grid Grid.Column="1" Margin="12,10">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Grid Grid.Row="0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                    <TextBlock x:Name="HostText" FontSize="13" FontWeight="SemiBold" Foreground="{DynamicResource Theme.Text.Primary}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}"/>
                    <TextBlock x:Name="IpText" FontSize="11" Foreground="{DynamicResource Theme.Text.Secondary}" Margin="0,1,0,0" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top">
                    <Button x:Name="ResetButton" Width="22" Height="22" Content="&#x21BB;" FontSize="14" FontWeight="SemiBold" Margin="0,0,0,2" Foreground="{DynamicResource Theme.Text.Muted}" ToolTip="Reset statistics" Style="{DynamicResource IconButtonStyle}"/>
                    <Button x:Name="PauseButton" Width="22" Height="22" Content="&#x275A;&#x275A;" FontSize="12" Foreground="{DynamicResource Theme.Text.Muted}" ToolTip="Pause monitoring" Style="{DynamicResource IconButtonStyle}"/>
                    <Button x:Name="RemoveButton" Width="22" Height="22" Content="&#x2716;" FontSize="9" Foreground="{DynamicResource Theme.Text.Muted}" ToolTip="Remove monitor" Style="{DynamicResource IconButtonStyle}"/>
                </StackPanel>
            </Grid>
            <Grid Grid.Row="1" Margin="0,6,0,4">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="LatencyText" FontSize="18" FontWeight="SemiBold" Foreground="{DynamicResource Theme.Status.Success}" VerticalAlignment="Center"/>
                <TextBlock x:Name="AvgText" Grid.Column="1" FontSize="11" Foreground="{DynamicResource Theme.Text.Muted}" VerticalAlignment="Center" TextAlignment="Right"/>
            </Grid>
            <Grid Grid.Row="2">
                <Grid.RowDefinitions>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Viewbox Grid.Row="0" Stretch="Uniform" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Margin="0,2,0,0">
                    <Canvas x:Name="GraphCanvas" Width="240" Height="60" Background="Transparent">
                        <Line X1="0" Y1="0" X2="240" Y2="0" Stroke="{DynamicResource Theme.Border}" StrokeThickness="0.75"/>
                        <Line X1="0" Y1="20" X2="240" Y2="20" Stroke="{DynamicResource Theme.Card.Border}" StrokeThickness="0.75"/>
                        <Line X1="0" Y1="40" X2="240" Y2="40" Stroke="{DynamicResource Theme.Card.Border}" StrokeThickness="0.75"/>
                        <Line X1="0" Y1="60" X2="240" Y2="60" Stroke="{DynamicResource Theme.Border}" StrokeThickness="0.75"/>
                        <Canvas x:Name="GraphBars" Width="240" Height="60" Background="Transparent"/>
                    </Canvas>
                </Viewbox>
                <Grid Grid.Row="1" Margin="0,2,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock x:Name="MinText" FontSize="10" Foreground="{DynamicResource Theme.Text.Muted}"/>
                    <TextBlock x:Name="DropText" Grid.Column="1" FontSize="10" Foreground="{DynamicResource Theme.Text.Muted}" TextAlignment="Center" Text="Drop: 0"/>
                    <TextBlock x:Name="MaxText" Grid.Column="2" FontSize="10" Foreground="{DynamicResource Theme.Text.Muted}" TextAlignment="Right"/>
                </Grid>
            </Grid>
        </Grid>
    </Grid>
</Border>
'@
function New-MonitorCard {
    param([Parameter(Mandatory)][string]$HostName)
    [xml]$xaml = $script:MonitorCardXaml
    $card = Read-XamlWindow -Xaml $xaml -ResourceDict $script:AppResources
    $controls = @{
        Card         = $card
        HostText     = $card.FindName('HostText')
        IpText       = $card.FindName('IpText')
        StatusAccent = $card.FindName('StatusAccent')
        LatencyText  = $card.FindName('LatencyText')
        AvgText      = $card.FindName('AvgText')
        MinText      = $card.FindName('MinText')
        DropText     = $card.FindName('DropText')
        MaxText      = $card.FindName('MaxText')
        GraphBars    = $card.FindName('GraphBars')
        ResetButton  = $card.FindName('ResetButton')
        PauseButton  = $card.FindName('PauseButton')
        RemoveButton = $card.FindName('RemoveButton')
    }
    $controls.HostText.Text = $HostName
    $card.Cursor = [System.Windows.Input.Cursors]::Arrow
    $card.AllowDrop = $true
    Register-CardDragSource -Card $card
    Register-DropTarget -Element $card
    foreach ($actionButton in @($controls.ResetButton, $controls.PauseButton, $controls.RemoveButton)) {
        $actionButton.Add_PreviewMouseLeftButtonDown({
                param($sender, $e)
                $ancestor = $sender.Parent
                while ($ancestor -and $ancestor -isnot [System.Windows.Controls.Border]) {
                    $ancestor = [System.Windows.Media.VisualTreeHelper]::GetParent($ancestor)
                }
                if ($ancestor -is [System.Windows.Controls.Border]) { $ancestor.Tag = $null }
            })
    }
    return $controls
}
function Get-RttColor {
    param([double]$RttMs)
    if ($RttMs -gt $script:Config.RttCriticalMs) { return $script:ThemeColors['Status.Critical'] }
    if ($RttMs -gt $script:Config.RttWarningMs) { return $script:ThemeColors['Status.Warning'] }
    return $script:ThemeColors['Status.Success']
}
function Set-MonitorGraphBarWidth {
    param([Parameter(Mandatory)]$Monitor)
    $samples = [Math]::Max(1, [int]$script:Settings.HistoryDepth)
    $Monitor.GraphBarGap = $script:Config.GraphBarGap
    $slotWidth = $script:Config.GraphWidth / [double]$samples
    $Monitor.GraphBarWidth = [Math]::Max(1.0, $slotWidth - $Monitor.GraphBarGap)
}
function New-RttBarBrush {
    param([System.Windows.Media.Color]$BaseColor)
    $brush = [System.Windows.Media.LinearGradientBrush]::new()
    $brush.StartPoint = [System.Windows.Point]::new(0.5, 0)
    $brush.EndPoint = [System.Windows.Point]::new(0.5, 1)
    $stops = @(
        @{ Alpha = 255; Offset = 0.0 }
        @{ Alpha = 255; Offset = 0.09 }
        @{ Alpha = 204; Offset = 0.09 }
        @{ Alpha = 50; Offset = 1.0 }
    )
    foreach ($stop in $stops) {
        $color = [System.Windows.Media.Color]::FromArgb($stop.Alpha, $BaseColor.R, $BaseColor.G, $BaseColor.B)
        $brush.GradientStops.Add([System.Windows.Media.GradientStop]::new($color, $stop.Offset))
    }
    if ($brush.CanFreeze) { $brush.Freeze() }
    return $brush
}
function Update-MonitorCard {
    param([Parameter(Mandatory)][hashtable]$Result)
    if (-not $script:Monitors.ContainsKey([string]$Result.MonitorId)) { return }
    $monitor = $script:Monitors[[string]$Result.MonitorId]
    $ui = $monitor.Controls
    $status = [string]$Result.Status
    if ($Result.Timestamp -isnot [DateTime]) { return }
    $sampleTimestamp = $Result.Timestamp.ToUniversalTime()
    if ($sampleTimestamp -lt $monitor.StatsResetUtc) { return }
    if ($status -eq 'Success') {
        $value = [double]$Result.RttMs
        $rttColor = Get-RttColor -RttMs $value
        $ui.IpText.Text = if ($null -ne $Result.Address) { [string]$Result.Address } else { '' }
        $ui.LatencyText.Text = '{0} ms' -f [long]$value
        $ui.LatencyText.Foreground = [System.Windows.Media.SolidColorBrush]::new($rttColor)
        if (-not $monitor.Paused) {
            $ui.StatusAccent.Background = [System.Windows.Media.SolidColorBrush]::new($rttColor)
        }
        $monitor.LastRtt = [long]$value
        if ($null -eq $monitor.LifetimeMin -or $value -lt [double]$monitor.LifetimeMin) { $monitor.LifetimeMin = [long]$value }
        if ($null -eq $monitor.LifetimeMax -or $value -gt [double]$monitor.LifetimeMax) { $monitor.LifetimeMax = [long]$value }
    }
    else {
        $ui.IpText.Text = if ($null -ne $Result.Address) { [string]$Result.Address } else { '' }
        $ui.LatencyText.Text = ($status -replace '(?-i)(?!^)([A-Z])', ' $1')
        $failureBrush = [System.Windows.Media.SolidColorBrush]::new($script:ThemeColors['Status.Failure'])
        $ui.LatencyText.Foreground = $failureBrush
        if (-not $monitor.Paused) {
            $ui.StatusAccent.Background = $failureBrush
        }
        if ($status -eq 'TimedOut') { $monitor.DroppedPackets++ }
    }
    $sample = [pscustomobject]@{
        Timestamp = $sampleTimestamp
        Status    = $status
        Address   = if ($null -ne $Result.Address) { [string]$Result.Address } else { $null }
        RttMs     = if ($status -eq 'Success') { [long]$Result.RttMs } else { $null }
        TimeoutMs = [int]$Result.TimeoutMs
    }
    $ui.MinText.Text = if ($null -ne $monitor.LifetimeMin) { "Min: $($monitor.LifetimeMin)" } else { '' }
    $ui.MaxText.Text = if ($null -ne $monitor.LifetimeMax) { "Max: $($monitor.LifetimeMax)" } else { '' }
    $ui.DropText.Text = "Drop: $($monitor.DroppedPackets)"
    if ($script:Settings.HistoryDepth -gt 0) {
        $monitor.History.Enqueue($sample)
        while ($monitor.History.Count -gt $script:Settings.HistoryDepth) { [void]$monitor.History.Dequeue() }
    }
    Update-MonitorGraph -Monitor $monitor
}
function Update-MonitorGraph {
    param([Parameter(Mandatory)]$Monitor)
    $ui = $Monitor.Controls
    $historyArray = @($Monitor.History)
    $count = $historyArray.Count
    $ui.GraphBars.Children.Clear()
    if ($count -eq 0) { $ui.AvgText.Text = ''; return }
    $validValues = @($historyArray | Where-Object { $_.Status -eq 'Success' -and $null -ne $_.RttMs } | ForEach-Object { [double]$_.RttMs })
    $ui.AvgText.Text = if ($validValues.Count -gt 0) {
        "Avg: $([math]::Round(($validValues | Measure-Object -Average).Average))"
    } else { 'Avg: -' }
    if ($Monitor.GraphBarWidth -le 0) { Set-MonitorGraphBarWidth -Monitor $Monitor }
    $barWidth = [double]$Monitor.GraphBarWidth
    $barGap = [double]$Monitor.GraphBarGap
    $slotWidth = $barWidth + $barGap
    $height = $script:Config.GraphHeight
    $graphWidth = $script:Config.GraphWidth
    for ($i = 0; $i -lt $count; $i++) {
        $sample = $historyArray[$i]
        $ageIndex = $count - 1 - $i
        $left = ($graphWidth - (($ageIndex + 1) * $slotWidth)) + ($barGap / 2.0)
        $timestampText = if ($sample.Timestamp -is [DateTime]) {
            $sample.Timestamp.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss.fff')
        } else { 'Unknown time' }
        $hitbox = [System.Windows.Shapes.Rectangle]::new()
        $hitbox.Width = $barWidth
        $hitbox.Height = $height
        $hitbox.Fill = [System.Windows.Media.Brushes]::Transparent
        $hitbox.Cursor = [System.Windows.Input.Cursors]::Hand
        $bar = [System.Windows.Shapes.Rectangle]::new()
        $bar.Width = $barWidth
        $bar.RadiusX = 1
        $bar.RadiusY = 1
        $bar.IsHitTestVisible = $false
        if ($sample.Status -eq 'Success') {
            $rtt = [double]$sample.RttMs
            $rttColor = Get-RttColor -RttMs $rtt
            $normalized = [Math]::Max(0.0, [Math]::Min(1.0, $rtt / $script:Config.GraphMaxRttMs))
            $bar.Height = [Math]::Max($script:Config.GraphMinBarHeight, $normalized * $height)
            $bar.Fill = New-RttBarBrush -BaseColor $rttColor
            $hitbox.ToolTip = "RTT: $([long]$rtt) ms`n$timestampText"
        }
        else {
            $bar.Height = $script:Config.GraphErrorBarHeight
            $bar.Fill = [System.Windows.Media.SolidColorBrush]::new($script:ThemeColors['Status.Failure'])
            $hitbox.ToolTip = "$($sample.Status)`nTimeout: $($sample.TimeoutMs) ms`n$timestampText"
        }
        [System.Windows.Controls.Canvas]::SetLeft($hitbox, $left)
        [System.Windows.Controls.Canvas]::SetTop($hitbox, 0)
        [void]$ui.GraphBars.Children.Add($hitbox)
        [System.Windows.Controls.Canvas]::SetLeft($bar, $left)
        [System.Windows.Controls.Canvas]::SetTop($bar, $height - $bar.Height)
        [void]$ui.GraphBars.Children.Add($bar)
    }
}
#endregion
#region 14.Views.MonitorRow
function New-HistoryDisplayItem {
    param([Parameter(Mandatory)]$Sample)
    $timestamp = if ($Sample.Timestamp -is [DateTime]) { $Sample.Timestamp.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss.fff') } else { 'Unknown time' }
    if ($Sample.Status -eq 'Success') {
        $color = Get-RttColor -RttMs ([double]$Sample.RttMs)
        $tooltip = "RTT: $([long]$Sample.RttMs) ms`n$timestamp"
    }
    else {
        $color = $script:ThemeColors['Status.Failure']
        $tooltip = "$($Sample.Status)`nTimeout: $($Sample.TimeoutMs) ms`n$timestamp"
    }
    [pscustomobject]@{
        Brush   = [System.Windows.Media.SolidColorBrush]::new($color)
        ToolTip = $tooltip
    }
}
function Update-MonitorRow {
    param([Parameter(Mandatory)]$Monitor, [Parameter(Mandatory)][hashtable]$Result)
    $status = [string]$Result.Status
    $Monitor.DisplayIp = if ($null -ne $Result.Address) { [string]$Result.Address } else { '' }
    $Monitor.DisplayLatency = if ($status -eq 'Success') { '{0} ms' -f [long]$Result.RttMs } else { $status -replace '(?-i)(?!^)([A-Z])', ' $1' }
    $Monitor.LatencyBrush = if ($status -eq 'Success') {
        [System.Windows.Media.SolidColorBrush]::new((Get-RttColor -RttMs ([double]$Result.RttMs)))
    } else { Get-ThemeBrush -Key 'Status.Failure' }
    $Monitor.DisplayMin = if ($null -ne $Monitor.LifetimeMin) { [string]$Monitor.LifetimeMin } else { '' }
    $Monitor.DisplayMax = if ($null -ne $Monitor.LifetimeMax) { [string]$Monitor.LifetimeMax } else { '' }
    $Monitor.DisplayDrop = [string]$Monitor.DroppedPackets
    $valid = @($Monitor.History | Where-Object { $_.Status -eq 'Success' -and $null -ne $_.RttMs } | ForEach-Object { [double]$_.RttMs })
    $Monitor.DisplayAvg = if ($valid.Count) { [string][math]::Round(($valid | Measure-Object -Average).Average) } else { '' }
    $Monitor.StatusBrush = if ($Monitor.Paused) { Get-ThemeBrush -Key 'Status.Neutral' } elseif ($status -eq 'Success') { [System.Windows.Media.SolidColorBrush]::new((Get-RttColor -RttMs ([double]$Result.RttMs))) } else { Get-ThemeBrush -Key 'Status.Failure' }
    $Monitor.HistoryDisplay.Clear()
    foreach ($sample in $Monitor.History) { [void]$Monitor.HistoryDisplay.Add((New-HistoryDisplayItem -Sample $sample)) }
}
#endregion
#region 13.Views.OptionsDialog

$script:OptionsFieldSpecs = @(
    [pscustomobject]@{ Name = 'Interval';     Control = 'IntervalInput'; Min = 0; Max = 3600;  Error = 'Interval must be between 0 and 3600 seconds.' }
    [pscustomobject]@{ Name = 'Timeout';      Control = 'TimeoutInput';  Min = 1; Max = [int]::MaxValue; Error = 'Timeout must be a positive whole number.' }
    [pscustomobject]@{ Name = 'BufferSize';   Control = 'BufferInput';   Min = 0; Max = 65500;  Error = 'Buffer size must be between 0 and 65500 bytes.' }
    [pscustomobject]@{ Name = 'Ttl';          Control = 'TtlInput';      Min = 1; Max = 255;    Error = 'TTL must be between 1 and 255.' }
    [pscustomobject]@{ Name = 'HistoryDepth'; Control = 'HistoryInput';  Min = 0; Max = 20;     Error = 'History samples must be between 0 and 20.' }
)
$script:OptionsDialogXaml = [xml]@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Options" Width="390" SizeToContent="Height" ResizeMode="NoResize" WindowStyle="None" WindowStartupLocation="CenterOwner" ShowInTaskbar="False" AllowsTransparency="True" Background="Transparent" FontFamily="Segoe UI" FontSize="13" SnapsToDevicePixels="True">
    <Border Margin="0" Background="{DynamicResource Theme.Window.Background}" BorderBrush="{DynamicResource Theme.Border}" BorderThickness="1" CornerRadius="10" ClipToBounds="True">
        <Border.Effect>
            <DropShadowEffect Color="#000000" BlurRadius="12" ShadowDepth="4" Opacity="0.12"/>

        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="32"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border x:Name="OptionsTitleBar" Grid.Row="0" Height="32" Background="{DynamicResource Theme.Toolbar.Background}" BorderBrush="{DynamicResource Theme.Divider}" BorderThickness="0,0,0,1" CornerRadius="9,9,0,0">
            <DockPanel>
                <Button x:Name="OptionsCloseButton" DockPanel.Dock="Right" Content="&#xE8BB;" ToolTip="Close" Style="{DynamicResource CaptionCloseButtonStyle}"/>
                <Viewbox x:Name="OptionsTitleLogoBox" Width="16" Height="16" Margin="10,0,8,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
                <TextBlock Text="Options" VerticalAlignment="Center" FontSize="12" Foreground="{DynamicResource Theme.Caption.Foreground}"/>
            </DockPanel>
        </Border>
            <Grid Grid.Row="1" Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Text="General" FontSize="14" FontWeight="Light" Foreground="{DynamicResource Theme.Text.Primary}" Margin="3,0,0,6">
            <TextBlock.Effect>
                <DropShadowEffect Color="DarkGray" Opacity="0.4" BlurRadius="3" ShadowDepth="1" Direction="270"/>
            </TextBlock.Effect>
        </TextBlock>
        <TextBlock Grid.Row="1" Text="Theme" Foreground="{DynamicResource Theme.Text.Primary}" VerticalAlignment="Center" Margin="0,5"/>
        <ComboBox x:Name="ThemeInput" Grid.Row="1" Grid.Column="1" Width="150" Height="32" Margin="0,5" Padding="10,4"/>
        <CheckBox x:Name="TopmostInput" Grid.Row="2" Grid.ColumnSpan="2" Content="Keep window always on top" Foreground="{DynamicResource Theme.Text.Primary}" Margin="0,8,0,4"/>
        <CheckBox x:Name="AutoSaveInput" Grid.Row="3" Grid.ColumnSpan="2" Content="Auto-save on exit" Foreground="{DynamicResource Theme.Text.Primary}" Margin="0,4,0,4"/>
        <Rectangle Grid.Row="4" Grid.ColumnSpan="2" Height="1" Fill="{DynamicResource Theme.Divider}" Margin="0,10,0,0"/>
        <TextBlock Grid.Row="5" Grid.ColumnSpan="2" Text="Ping" FontSize="14" FontWeight="Light" Foreground="{DynamicResource Theme.Text.Primary}" Margin="3,14,0,6">
            <TextBlock.Effect>
                <DropShadowEffect Color="DarkGray" Opacity="0.4" BlurRadius="3" ShadowDepth="1" Direction="270"/>
            </TextBlock.Effect>
        </TextBlock>
        <TextBlock Grid.Row="6" Text="Interval (seconds)" Foreground="{DynamicResource Theme.Text.Primary}" VerticalAlignment="Center" Margin="0,5"/>
        <TextBox x:Name="IntervalInput" Grid.Row="6" Grid.Column="1" Margin="0,5"/>
        <TextBlock Grid.Row="7" Text="Timeout (milliseconds)" Foreground="{DynamicResource Theme.Text.Primary}" VerticalAlignment="Center" Margin="0,5"/>
        <TextBox x:Name="TimeoutInput" Grid.Row="7" Grid.Column="1" Margin="0,5"/>
        <TextBlock Grid.Row="8" Text="Buffer size (bytes)" Foreground="{DynamicResource Theme.Text.Primary}" VerticalAlignment="Center" Margin="0,5"/>
        <TextBox x:Name="BufferInput" Grid.Row="8" Grid.Column="1" Margin="0,5"/>
        <TextBlock Grid.Row="9" Text="TTL (hops)" Foreground="{DynamicResource Theme.Text.Primary}" VerticalAlignment="Center" Margin="0,5"/>
        <TextBox x:Name="TtlInput" Grid.Row="9" Grid.Column="1" Margin="0,5"/>
        <TextBlock Grid.Row="10" Text="History samples" Foreground="{DynamicResource Theme.Text.Primary}" VerticalAlignment="Center" Margin="0,5"/>
        <TextBox x:Name="HistoryInput" Grid.Row="10" Grid.Column="1" Margin="0,5"/>
        <CheckBox x:Name="DontFragmentInput" Grid.Row="11" Grid.ColumnSpan="2" Content="Do not fragment packets" Foreground="{DynamicResource Theme.Text.Primary}" Margin="0,8,0,16"/>
        <StackPanel Grid.Row="12" Grid.ColumnSpan="2" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="CancelButton" Content="Cancel" IsCancel="True" Style="{DynamicResource PrimaryButtonStyle}" MinWidth="80"/>
            <Button x:Name="OkButton" Content="Apply" IsDefault="True" MinWidth="80" Style="{DynamicResource ActionButtonStyle}"/>
        </StackPanel>
            </Grid>
        </Grid>
    </Border>
</Window>
'@
function Read-OptionsFields {
    param([Parameter(Mandatory)]$Dialog)
    $values = @{}
    foreach ($spec in $script:OptionsFieldSpecs) {
        $text = $Dialog.FindName($spec.Control).Text
        $parsed = 0
        $ok = [int]::TryParse($text, [ref]$parsed) -and $parsed -ge $spec.Min -and $parsed -le $spec.Max
        if (-not $ok) {
            Show-MessageBox -Message $spec.Error -Title 'Invalid option' -Icon Warning
            return $null
        }
        $values[$spec.Name] = $parsed
    }
    return $values
}
function Show-OptionsWindow {
    $dialog = Read-XamlWindow -Xaml $script:OptionsDialogXaml -ResourceDict $script:AppResources
    $dialog.Owner = $Window
    $script:OptionsDialog = $dialog
    [System.Windows.Shell.WindowChrome]::SetWindowChrome($dialog, (New-CustomWindowChrome))
    $dialog.Icon = New-AppIconSource
    $dialog.FindName('OptionsTitleLogoBox').Child = New-AppLogoVisual
    $dialog.FindName('OptionsCloseButton').Add_Click({ $dialog.Close() })
    $dialog.FindName('IntervalInput').Text = $script:Settings.Interval
    $dialog.FindName('TimeoutInput').Text = $script:Settings.Timeout
    $dialog.FindName('BufferInput').Text = $script:Settings.BufferSize
    $dialog.FindName('TtlInput').Text = $script:Settings.Ttl
    $dialog.FindName('HistoryInput').Text = $script:Settings.HistoryDepth
    $dialog.FindName('DontFragmentInput').IsChecked = $script:Settings.DontFragment
    $dialog.FindName('TopmostInput').IsChecked = $Window.Topmost
    $dialog.FindName('AutoSaveInput').IsChecked = $script:AutoSaveOnExit
    $themeCombo = $dialog.FindName('ThemeInput')
    $themeCombo.ItemsSource = @($script:ThemeRegistry.Keys)
    $themeCombo.SelectedItem = $script:ThemeName
    $dialog.FindName('CancelButton').Add_Click({ $dialog.DialogResult = $false })
    $dialog.FindName('OkButton').Add_Click({
            $values = Read-OptionsFields -Dialog $dialog
            if (-not $values) { return }
            Set-MonitoringSettings -Interval $values.Interval -Timeout $values.Timeout -BufferSize $values.BufferSize `
                -HistoryDepth $values.HistoryDepth -Ttl $values.Ttl -DontFragment ([bool]$dialog.FindName('DontFragmentInput').IsChecked)
            $Window.Topmost = [bool]$dialog.FindName('TopmostInput').IsChecked
            $script:AutoSaveOnExit = [bool]$dialog.FindName('AutoSaveInput').IsChecked
            $selectedTheme = [string]$themeCombo.SelectedItem
            if (-not [string]::IsNullOrEmpty($selectedTheme) -and $selectedTheme -ne $script:ThemeName) {
                [void](Set-AppTheme -ThemeName $selectedTheme)
            }
            foreach ($monitor in $script:Monitors.Values) {
                while ($monitor.History.Count -gt $script:Settings.HistoryDepth) { [void]$monitor.History.Dequeue() }
            }
            $dialog.DialogResult = $true
        })
    [void]$dialog.ShowDialog()
}
#endregion
#region 20.ViewModel.DragDrop

function Get-DropIndicator {
    if (-not $script:DropIndicator) {
        $indicator = [System.Windows.Controls.Border]::new()
        $indicator.Width = 4
        $indicator.CornerRadius = [System.Windows.CornerRadius]::new(2)
        $indicator.Background = [System.Windows.Media.SolidColorBrush]::new($script:ThemeColors['Accent'])
        $indicator.IsHitTestVisible = $false
        $indicator.Opacity = 0.65
        $indicator.Visibility = [System.Windows.Visibility]::Hidden
        if ($script:DropIndicatorOverlay) {
            [void]$script:DropIndicatorOverlay.Children.Add($indicator)
        }
        $script:DropIndicator = $indicator
    }
    return $script:DropIndicator
}
function Hide-DropIndicator {
    if ($script:DropIndicator) { $script:DropIndicator.Visibility = [System.Windows.Visibility]::Hidden }
}
function Get-WrapPanelInsertIndex {
    param(
        [System.Windows.Controls.WrapPanel]$Panel,
        [System.Windows.Point]$Position,
        [System.Windows.UIElement]$DraggedCard
    )
    $insertBeforeWeight = $script:Config.InsertBeforeWeight
    $children = @($Panel.Children | Where-Object { -not [object]::ReferenceEquals($_, $DraggedCard) })
    for ($i = 0; $i -lt $children.Count; $i++) {
        $child = $children[$i]
        $slot = [System.Windows.Controls.Primitives.LayoutInformation]::GetLayoutSlot($child)
        $insertBeforeX = $slot.Left + ($slot.Width * $insertBeforeWeight)
        if ($Position.Y -lt $slot.Top) { return $i }
        if ($Position.Y -le ($slot.Top + $slot.Height)) {
            if ($Position.X -lt $insertBeforeX) { return $i }
            continue
        }
        if ($i + 1 -lt $children.Count) {
            $next = $children[$i + 1]
            $nextSlot = [System.Windows.Controls.Primitives.LayoutInformation]::GetLayoutSlot($next)
            if ($nextSlot.Top -gt $slot.Top -and $Position.Y -lt $nextSlot.Top) { return $i + 1 }
        }
    }
    return $children.Count
}
function Update-DropIndicator {
    param([System.Windows.Point]$Position)
    if (-not $script:DraggingCard -or -not $MonitorPanel -or -not $script:DropIndicatorOverlay) {
        Hide-DropIndicator
        return
    }
    $insertIndex = Get-WrapPanelInsertIndex -Panel $MonitorPanel -Position $Position -DraggedCard $script:DraggingCard
    $children = @($MonitorPanel.Children | Where-Object { -not [object]::ReferenceEquals($_, $script:DraggingCard) })
    if ($children.Count -eq 0) {
        $x = 13; $y = 10; $height = 84
    }
    else {
        $target = if ($insertIndex -lt $children.Count) { $children[$insertIndex] } else { $children[$children.Count - 1] }
        $slot = [System.Windows.Controls.Primitives.LayoutInformation]::GetLayoutSlot($target)
        $y = $slot.Top + 10
        $height = [Math]::Max(56, $slot.Height - 20)
        $x = if ($insertIndex -lt $children.Count) { [Math]::Max(0, $slot.Left) } else { $slot.Left + $slot.Width + 1 }
    }
    $indicator = Get-DropIndicator
    [System.Windows.Controls.Canvas]::SetLeft($indicator, $x - $MonitorScroll.HorizontalOffset)
    [System.Windows.Controls.Canvas]::SetTop($indicator, $y - $MonitorScroll.VerticalOffset)
    $indicator.Height = $height
    $indicator.Visibility = [System.Windows.Visibility]::Visible
}
function Update-MonitorSequences {
    $seq = 1
    foreach ($child in $MonitorPanel.Children) {
        $mon = $script:Monitors.Values | Where-Object { $_.Controls.Card -eq $child }
        if ($mon) { $mon.Sequence = $seq++ }
    }
    Sync-TablePanelOrder
}
function Invoke-CardDragOver {
    param($Sender, $EventArgs)
    if (-not $script:DraggingCard) {
        $EventArgs.Effects = [System.Windows.DragDropEffects]::None
        $EventArgs.Handled = $true
        return
    }
    $EventArgs.Effects = [System.Windows.DragDropEffects]::Move
    if ([object]::ReferenceEquals($script:DraggingCard, $Sender)) {
        Hide-DropIndicator
    }
    else {
        Update-DropIndicator -Position $EventArgs.GetPosition($MonitorPanel)
    }
    $EventArgs.Handled = $true
}
function Invoke-CardDrop {
    param($Sender, $EventArgs)
    Hide-DropIndicator
    $draggedCard = $script:DraggingCard
    if ($draggedCard -isnot [System.Windows.Controls.Border] -or [object]::ReferenceEquals($draggedCard, $Sender)) {
        $EventArgs.Handled = $true
        return
    }
    $position = $EventArgs.GetPosition($MonitorPanel)
    $index = Get-WrapPanelInsertIndex -Panel $MonitorPanel -Position $position -DraggedCard $draggedCard
    if ($draggedCard.Parent -is [System.Windows.Controls.WrapPanel]) {
        [void]$draggedCard.Parent.Children.Remove($draggedCard)
    }
    $index = [Math]::Max(0, [Math]::Min($index, $MonitorPanel.Children.Count))
    [void]$MonitorPanel.Children.Insert($index, $draggedCard)
    Update-MonitorSequences
    $EventArgs.Handled = $true
}
function Register-DropTarget {
    param([Parameter(Mandatory)]$Element)
    $Element.AllowDrop = $true
    [void]$Element.Add_DragOver({ param($sender, $e) Invoke-CardDragOver -Sender $sender -EventArgs $e })
    [void]$Element.Add_Drop({ param($sender, $e) Invoke-CardDrop -Sender $sender -EventArgs $e })
}
function Register-CardDragSource {
    param([Parameter(Mandatory)][System.Windows.Controls.Border]$Card)
    $Card.Add_PreviewMouseLeftButtonDown({
            param($sender, $e)
            if ($e.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) { $sender.Tag = $e.GetPosition($sender) }
        })
    $Card.Add_PreviewMouseLeftButtonUp({ param($sender, $e) $sender.Tag = $null })
    $Card.Add_PreviewMouseMove({
            param($sender, $e)
            if ($e.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { $sender.Tag = $null; return }
            if ($null -eq $sender.Tag -or $script:DraggingCard) { return }
            $start = $sender.Tag
            $current = $e.GetPosition($sender)
            $threshold = $script:Config.DragThresholdPx
            if ([Math]::Abs($current.X - $start.X) -lt $threshold -and [Math]::Abs($current.Y - $start.Y) -lt $threshold) { return }
            $sender.Tag = $null
            $script:DraggingCard = $sender
            $sender.Opacity = 0.5
            try {
                $data = [System.Windows.DataObject]::new()
                $data.SetData('PingMonitorCard', 'Move')
                [void][System.Windows.DragDrop]::DoDragDrop($sender, $data, [System.Windows.DragDropEffects]::Move)
            }
            finally {
                $sender.Opacity = 1.0
                Hide-DropIndicator
                $script:DraggingCard = $null
            }
        })
}
#endregion
#region 25.ViewModel.TableView

$script:TableColumnVisibility = [ordered]@{ Status=$true; Host=$true; IP=$true; Latency=$true; Avg=$true; Min=$true; Max=$true; Drop=$true; History=$true }
function Get-VisualAncestor {
    param($Start, [Parameter(Mandatory)][type]$Type)
    $current = $Start
    while ($current) {
        if ($Type.IsInstanceOfType($current)) { return $current }
        try { $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current) } catch { $current = [System.Windows.LogicalTreeHelper]::GetParent($current) }
    }
    return $null
}
function Sync-CardPanelOrder {
    if (-not $MonitorPanel) { return }
    $ordered = @($script:Monitors.Values | Sort-Object Sequence)
    for ($i=0; $i -lt $ordered.Count; $i++) {
        $card=$ordered[$i].Controls.Card; $current=$MonitorPanel.Children.IndexOf($card)
        if ($current -ge 0 -and $current -ne $i) { [void]$MonitorPanel.Children.Remove($card); [void]$MonitorPanel.Children.Insert($i,$card) }
    }
}
function Sync-TablePanelOrder {
    if (-not $TableGrid) { return }
    $ordered=@($script:Monitors.Values | Sort-Object Sequence)
    $TableGrid.Items.Clear()
    foreach ($monitor in $ordered) { [void]$TableGrid.Items.Add($monitor) }
}
function Update-TableRowSequences {
    $sequence=1
    foreach ($monitor in @($TableGrid.Items)) { $monitor.Sequence=$sequence++ }
    Sync-CardPanelOrder
}
function Invoke-RowActionMenuItemClick {
    param($Sender, $EventArgs)
    $parts = ([string]$Sender.Tag).Split('|')
    if (-not $script:Monitors.ContainsKey($parts[0])) { return }
    $target = $script:Monitors[$parts[0]]
    switch ($parts[1]) {
        'Reset'  { Reset-MonitorStatistics -Monitor $target }
        'Pause'  { Set-MonitorsPaused -Monitor $target }
        'Remove' { Stop-Monitor -Monitor $target -RemoveCard }
    }
    $TableGrid.Items.Refresh()
    $EventArgs.Handled = $true
}
function New-RowActionMenuItem {
    param([string]$Header,[string]$IconData,[string]$Tag)
    $item = [System.Windows.Controls.MenuItem]::new()
    $item.Header = $Header
    $item.Tag = $Tag
    $item.Foreground = Get-ThemeBrush -Key 'MenuItem.TextFill'
    $icon = [System.Windows.Shapes.Path]::new()
    $icon.Data = [System.Windows.Media.Geometry]::Parse($IconData)
    $icon.Fill = Get-ThemeBrush -Key 'MenuItem.IconFill'
    $icon.Width = 14; $icon.Height = 14; $icon.Stretch = 'Uniform'
    $item.Icon = $icon
    $item.Add_Click({ param($sender,$e) Invoke-RowActionMenuItemClick -Sender $sender -EventArgs $e })
    return $item
}
function Show-RowActionMenu {
    param([Parameter(Mandatory)][System.Windows.FrameworkElement]$Button,[Parameter(Mandatory)]$Monitor)
    $menu = [System.Windows.Controls.ContextMenu]::new()
    $menu.Style = $Window.FindResource('ThemedContextMenuStyle')
    $menu.Background = Get-ThemeBrush -Key 'Popup.Background'
    $menu.BorderBrush = Get-ThemeBrush -Key 'Popup.Border'
    $menu.BorderThickness = [System.Windows.Thickness]::new(1)
    $menu.PlacementTarget = $Button
    $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::MousePoint
    [void]$menu.Items.Add((New-RowActionMenuItem -Header 'Reset' -IconData $script:GlobalActionIcons.Reset -Tag "$($Monitor.Id)|Reset"))
    $pauseIcon = if ($Monitor.Paused) { $script:GlobalActionIcons.Resume } else { $script:GlobalActionIcons.Pause }
    $pauseText = if ($Monitor.Paused) { 'Resume' } else { 'Pause' }
    [void]$menu.Items.Add((New-RowActionMenuItem -Header $pauseText -IconData $pauseIcon -Tag "$($Monitor.Id)|Pause"))
    [void]$menu.Items.Add((New-RowActionMenuItem -Header 'Remove' -IconData $script:GlobalActionIcons.Clear -Tag "$($Monitor.Id)|Remove"))
    $menu.IsOpen = $true
}
function Invoke-ColumnVisibilityMenuItemClick {
    param($Sender)
    $name = [string]$Sender.Tag
    $script:TableColumnVisibility[$name] = [bool]$Sender.IsChecked
    $column = $TableGrid.Columns | Where-Object { [string]$_.SortMemberPath -eq $name } | Select-Object -First 1
    if ($column) { $column.Visibility = if ($Sender.IsChecked) { 'Visible' } else { 'Collapsed' } }
}
function Show-ColumnVisibilityMenu {
    param([Parameter(Mandatory)][System.Windows.FrameworkElement]$PlacementTarget)
    $menu = [System.Windows.Controls.ContextMenu]::new()
    $menu.Style = $Window.FindResource('ThemedContextMenuStyle')
    $menu.Background = Get-ThemeBrush -Key 'Popup.Background'
    $menu.BorderBrush = Get-ThemeBrush -Key 'Popup.Border'
    $menu.BorderThickness = [System.Windows.Thickness]::new(1)
    $menu.PlacementTarget = $PlacementTarget
    $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::MousePoint
    foreach ($name in $script:TableColumnVisibility.Keys) {
        $item = [System.Windows.Controls.MenuItem]::new()
        $item.Header = $name
        $item.Tag = $name
        $item.Foreground = Get-ThemeBrush -Key 'MenuItem.TextFill'
        $item.IsCheckable = $true
        $item.IsChecked = [bool]$script:TableColumnVisibility[$name]
        $item.StaysOpenOnClick = $true
        $item.Add_Click({ param($sender,$e) Invoke-ColumnVisibilityMenuItemClick -Sender $sender })
        [void]$menu.Items.Add($item)
    }
    $menu.IsOpen = $true
}

function Initialize-DataGridActions {
    $TableGrid.Add_PreviewMouseWheel({param($sender,$e)
        if(-not [System.Windows.Input.Keyboard]::IsKeyDown([System.Windows.Input.Key]::LeftShift) -and
           -not [System.Windows.Input.Keyboard]::IsKeyDown([System.Windows.Input.Key]::RightShift)){return}
        $scrollViewer=Get-VisualAncestor -Start $e.OriginalSource -Type ([System.Windows.Controls.ScrollViewer])
        if(-not $scrollViewer){return}
        $scrollViewer.ScrollToHorizontalOffset($scrollViewer.HorizontalOffset - $e.Delta)
        $e.Handled=$true
    })
    $TableGrid.Add_PreviewMouseRightButtonDown({param($sender,$e)
        $header=Get-VisualAncestor -Start $e.OriginalSource -Type ([System.Windows.Controls.Primitives.DataGridColumnHeader])
        if($header){ $e.Handled=$true; return }
        $row=Get-VisualAncestor -Start $e.OriginalSource -Type ([System.Windows.Controls.DataGridRow])
        if($row){ $row.IsSelected=$true; $e.Handled=$true }
    })
    $TableGrid.Add_PreviewMouseRightButtonUp({param($sender,$e)
        $header=Get-VisualAncestor -Start $e.OriginalSource -Type ([System.Windows.Controls.Primitives.DataGridColumnHeader])
        if($header){
            Show-ColumnVisibilityMenu -PlacementTarget $header
            $e.Handled=$true
            return
        }
        $row=Get-VisualAncestor -Start $e.OriginalSource -Type ([System.Windows.Controls.DataGridRow])
        if($row -and $row.Item){
            Show-RowActionMenu -Button $row -Monitor $row.Item
            $e.Handled=$true
        }
    })
}
function Hide-DataGridDropLine {
    if($TableDropLine){$TableDropLine.Visibility='Collapsed'}
}
function Show-DataGridDropLine {
    param([System.Windows.Controls.DataGridRow]$TargetRow,[bool]$After)
    if(-not $TargetRow){Hide-DataGridDropLine;return}
    $point=$TargetRow.TranslatePoint([System.Windows.Point]::new(0,0),$TableDragOverlay)
    $TableDropLine.Width=[Math]::Max(40,$TableGrid.ActualWidth)
    [System.Windows.Controls.Canvas]::SetLeft($TableDropLine,0)
    $dropY=$point.Y
    if($After){$dropY += $TargetRow.ActualHeight}
    [System.Windows.Controls.Canvas]::SetTop($TableDropLine,$dropY-1.5)
    $TableDropLine.Visibility='Visible'
}
function Initialize-DataGridDragDrop {
    $TableGrid.Add_PreviewMouseLeftButtonDown({param($sender,$e)
        if(Get-VisualAncestor -Start $e.OriginalSource -Type ([System.Windows.Controls.Button])){
            $script:DraggingRow=$null;$script:DraggedMonitor=$null;return
        }
        $row=Get-VisualAncestor -Start $e.OriginalSource -Type ([System.Windows.Controls.DataGridRow])
        $script:DraggingRow=$row
        $script:DraggedMonitor=if($row){$row.Item}else{$null}
        $script:RowDragStart=$e.GetPosition($TableGrid)
    })
    $TableGrid.Add_PreviewMouseLeftButtonUp({param($sender,$e)
        $script:DraggingRow=$null;$script:DraggedMonitor=$null
    })
    $TableGrid.Add_PreviewMouseMove({param($sender,$e)
        if(-not $script:DraggingRow -or $e.LeftButton -ne 'Pressed'){return}
        $p=$e.GetPosition($TableGrid)
        if([Math]::Abs($p.X-$script:RowDragStart.X)-lt $script:Config.DragThresholdPx -and [Math]::Abs($p.Y-$script:RowDragStart.Y)-lt $script:Config.DragThresholdPx){return}
        $draggedRow=$script:DraggingRow
        $draggedMonitor=$script:DraggedMonitor
        $script:DraggingRow=$null
        $draggedRow.IsSelected=$true; $draggedRow.Opacity=.65
        $data = New-Object System.Windows.DataObject
        [void]$data.SetData('PingMonitorMonitor', $draggedMonitor)
        try{[void][System.Windows.DragDrop]::DoDragDrop($draggedRow,$data,[System.Windows.DragDropEffects]::Move)}
        finally{$script:DraggedMonitor=$null;$draggedRow.Opacity=1;Hide-DataGridDropLine}
    })
    $TableGrid.Add_DragOver({param($sender,$e)
        $target=Get-VisualAncestor -Start $e.OriginalSource -Type ([System.Windows.Controls.DataGridRow])
        $after=$target -and ($e.GetPosition($target).Y -gt ($target.ActualHeight/2))
        Show-DataGridDropLine -TargetRow $target -After $after
        $e.Effects='Move';$e.Handled=$true
    })
    $TableGrid.Add_DragLeave({Hide-DataGridDropLine})
    $TableGrid.Add_Drop({param($sender,$e)
        $item=$null
        try { $item=$e.Data.GetData('PingMonitorMonitor') } catch { $item=$null }
        if(-not $item){ $item=$script:DraggedMonitor }
        if(-not $item){Hide-DataGridDropLine;return}
        $target=Get-VisualAncestor -Start $e.OriginalSource -Type ([System.Windows.Controls.DataGridRow])
        $old=$TableGrid.Items.IndexOf($item); if($old -lt 0){return}
        $new=if($target){$target.GetIndex()}else{$TableGrid.Items.Count-1}
        if($target -and $e.GetPosition($target).Y -gt ($target.ActualHeight/2)){$new++}
        [void]$TableGrid.Items.Remove($item);if($new -gt $old){$new--};$new=[Math]::Max(0,[Math]::Min($new,$TableGrid.Items.Count));[void]$TableGrid.Items.Insert($new,$item)
        Update-TableRowSequences;Hide-DataGridDropLine;$e.Handled=$true
    })
}
#endregion
#region 21.ViewModel.Monitor

function Get-MonitorNames {
    @($script:Monitors.Values | Sort-Object Sequence | ForEach-Object HostName)
}
function Set-StatusText {
    param([string]$Text)
    $StatusText.Text = $Text
}
function Test-ValidHostName {
    param([string]$HostName)
    $address = $null
    $isIp = [System.Net.IPAddress]::TryParse($HostName, [ref]$address) -and ($address.IPAddressToString -eq $HostName)
    $fqdnPattern = '^(?i)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$'
    $labelPattern = '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$'
    $isDns = $HostName -match "$fqdnPattern|$labelPattern"
    [pscustomobject]@{ IsValid = ($isIp -or $isDns); IsLiteralIp = $isIp }
}
function New-MonitorModel {
    param([Parameter(Mandatory)][string]$HostName, [Parameter(Mandatory)][bool]$IsLiteralIp, [Parameter(Mandatory)][hashtable]$Controls)
    [pscustomobject]@{
        Id             = [guid]::NewGuid().Guid
        Sequence       = ++$script:Sequence
        HostName       = $HostName
        IsLiteralIp    = $IsLiteralIp
        Controls       = $Controls
        History        = [System.Collections.Generic.Queue[psobject]]::new()
        HistoryDisplay = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
        DisplayIp      = ''
        DisplayLatency = ''
        DisplayAvg     = ''
        DisplayMin     = ''
        DisplayMax     = ''
        DisplayDrop    = '0'
        StatusBrush    = Get-ThemeBrush -Key 'Status.Neutral'
        LatencyBrush   = Get-ThemeBrush -Key 'Text.Secondary'
        LifetimeMin    = $null
        LifetimeMax    = $null
        DroppedPackets = 0
        LastRtt        = $null
        StatsResetUtc  = [DateTime]::UtcNow
        Paused         = [bool]$script:GlobalPaused
        NextDueUtc     = [DateTime]::UtcNow
        AttemptId      = 0
        InFlight       = $false
        IsStopping     = $false
        GraphBarGap    = $script:Config.GraphBarGap
        GraphBarWidth  = 1.0
        PowerShell     = $null
        AsyncResult    = $null
    }
}
function Add-Monitor {
    param([string]$HostName)
    $HostName = $HostName.Trim()
    $validation = Test-ValidHostName -HostName $HostName
    if ([string]::IsNullOrWhiteSpace($HostName) -or -not $validation.IsValid) {
        Show-MessageBox -Message 'Enter a valid hostname or IP address.' -Title 'Input required' -Icon Warning
        $HostInput.Focus()
        return
    }
    if ($script:Monitors.Values | Where-Object { $_.HostName -ieq $HostName } | Select-Object -First 1) {
        Show-MessageBox -Message "'$HostName' is already being monitored." -Title 'Duplicate host' -Icon Information
        $HostInput.SelectAll(); $HostInput.Focus()
        return
    }
    $controls = New-MonitorCard -HostName $HostName
    $monitor = New-MonitorModel -HostName $HostName -IsLiteralIp $validation.IsLiteralIp -Controls $controls
    Set-MonitorGraphBarWidth -Monitor $monitor
    $controls.ResetButton.Tag = $monitor.Id
    $controls.PauseButton.Tag = $monitor.Id
    $controls.RemoveButton.Tag = $monitor.Id
    $controls.ResetButton.Add_Click({ param($sender, $e) if ($script:Monitors.ContainsKey([string]$sender.Tag)) { Reset-MonitorStatistics -Monitor $script:Monitors[[string]$sender.Tag] } })
    $controls.PauseButton.Add_Click({ param($sender, $e) if ($script:Monitors.ContainsKey([string]$sender.Tag)) { Set-MonitorsPaused -Monitor $script:Monitors[[string]$sender.Tag] } })
    $controls.RemoveButton.Add_Click({ param($sender, $e) if ($script:Monitors.ContainsKey([string]$sender.Tag)) { Stop-Monitor -Monitor $script:Monitors[[string]$sender.Tag] -RemoveCard } })
    $script:Monitors[$monitor.Id] = $monitor
    $LogoViewBox.Visibility = if ($script:Monitors.Count) { 'Collapsed' } else { 'Visible' }
    [void]$MonitorPanel.Children.Add($controls.Card)
    [void]$TableGrid.Items.Add($monitor)
    if ($monitor.Paused) {
        $controls.PauseButton.Content = [char]0x25B6
        $controls.PauseButton.ToolTip = 'Resume monitoring'
        $controls.StatusAccent.Background = [System.Windows.Media.SolidColorBrush]::new($script:ThemeColors['Status.Neutral'])
        $monitor.StatusBrush = Get-ThemeBrush -Key 'Status.Neutral' 
    }
    $HostInput.Clear()
    $HostInput.Focus()
    Set-StatusText ("Monitoring {0} host(s)" -f $script:Monitors.Count)
}
function Stop-Monitor {
    param([Parameter(Mandatory)]$Monitor, [switch]$RemoveCard)
    $Monitor.IsStopping = $true
    if ($RemoveCard) {
        if ($Monitor.Controls.Card.Parent) { [void]$MonitorPanel.Children.Remove($Monitor.Controls.Card) }
        if ($TableGrid.Items.Contains($Monitor)) { [void]$TableGrid.Items.Remove($Monitor) }
    }
    [void]$script:Monitors.Remove($Monitor.Id)
    $script:RetiredMonitors[$Monitor.Id] = $Monitor
    if ($Monitor.InFlight -and $Monitor.PowerShell) {
        try { [void]$Monitor.PowerShell.BeginStop($null, $null) }
        catch { Write-Verbose "BeginStop failed for '$($Monitor.HostName)': $_" }
    }
    $LogoViewBox.Visibility = if ($script:Monitors.Count) { 'Collapsed' } else { 'Visible' }
    Set-StatusText ("Monitoring {0} host(s)" -f $script:Monitors.Count)
}
function Clear-Monitors {
    foreach ($monitor in @($script:Monitors.Values)) {
        [void](Stop-Monitor -Monitor $monitor -RemoveCard)
    }
}
function Reset-MonitorStatistics {
    param([Parameter(Mandatory)]$Monitor)
    $Monitor.History.Clear()
    $Monitor.LifetimeMin = $null
    $Monitor.LifetimeMax = $null
    $Monitor.DroppedPackets = 0
    $Monitor.LastRtt = $null
    $Monitor.StatsResetUtc = [DateTime]::UtcNow
    $ui = $Monitor.Controls
    $ui.LatencyText.Text = ''
    $ui.LatencyText.Foreground = [System.Windows.Media.SolidColorBrush]::new($script:ThemeColors['Text.Secondary'])
    $ui.IpText.Text = ''
    $ui.StatusAccent.Background = [System.Windows.Media.SolidColorBrush]::new($script:ThemeColors['Status.Neutral'])
    $ui.AvgText.Text = ''
    $ui.MinText.Text = ''
    $ui.DropText.Text = 'Drop: 0'
    $ui.MaxText.Text = ''
    $ui.GraphBars.Children.Clear()
    $Monitor.DisplayIp=''; $Monitor.DisplayLatency=''; $Monitor.DisplayAvg=''; $Monitor.DisplayMin=''; $Monitor.DisplayMax=''; $Monitor.DisplayDrop='0'
    $Monitor.StatusBrush=Get-ThemeBrush -Key 'Status.Neutral'
    $Monitor.LatencyBrush=Get-ThemeBrush -Key 'Text.Secondary'
    $Monitor.HistoryDisplay.Clear()
    if (-not $Monitor.InFlight -and -not $Monitor.IsStopping -and -not $Monitor.Paused) {
        $Monitor.NextDueUtc = [DateTime]::UtcNow
    }
}
function Set-MonitorsPaused {
    param(
        [Parameter(ParameterSetName='Single', Mandatory)][object]$Monitor,
        [Parameter(ParameterSetName='All', Mandatory)][bool]$Paused
    )
    $monitors = if ($PSCmdlet.ParameterSetName -eq 'All') {
        $script:GlobalPaused = $Paused
        @($script:Monitors.Values)
    } else {
        @($Monitor)
    }
    $neutralBrush = [System.Windows.Media.SolidColorBrush]::new($script:ThemeColors['Status.Neutral'])
    foreach ($item in $monitors) {
        if ($item.IsStopping) { continue }
        $item.Paused = if ($PSCmdlet.ParameterSetName -eq 'All') { $Paused } else { -not $item.Paused }
        if ($item.Paused) {
            $item.Controls.PauseButton.Content = [char]0x25B6
            $item.Controls.PauseButton.ToolTip = 'Resume monitoring'
            $item.Controls.StatusAccent.Background = $neutralBrush
            $item.StatusBrush = $neutralBrush
        } else {
            $item.Controls.PauseButton.Content = [char]0x275A + [char]0x275A
            $item.Controls.PauseButton.ToolTip = 'Pause monitoring'
            $item.NextDueUtc = [DateTime]::UtcNow
            if ($PSCmdlet.ParameterSetName -eq 'Single' -and $script:GlobalPaused) { $script:GlobalPaused = $false; Update-GlobalActionButton }
        }
    }
    if ($TableGrid) { $TableGrid.Items.Refresh() }
}
#endregion
#region 22.ViewModel.PingEngine

function Initialize-PingEngine {
    $script:UpdateQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
    $script:RunningPingTasks = 0
    $script:RunspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $script:Config.MaxConcurrentPings)
    $script:RunspacePool.ApartmentState = [System.Threading.ApartmentState]::MTA
    $script:RunspacePool.Open()
}
function Get-CurrentPingSettings {
    [pscustomobject]@{
        Interval     = [int]$script:Settings.Interval
        Timeout      = [int]$script:Settings.Timeout
        BufferSize   = [int]$script:Settings.BufferSize
        Ttl          = [int]$script:Settings.Ttl
        DontFragment = [bool]$script:Settings.DontFragment
    }
}
$script:PingWorkerScript = {
    param($MonitorId, $HostName, $IsLiteralIp, $AttemptId, $AttemptStartedUtc, $Settings, $Queue)
    $pingStartedUtc = $null
    $address = $null
    $ping = $null
    $phase = 'Resolve'
    try {
        if ($IsLiteralIp) {
            $address = [System.Net.IPAddress]::Parse($HostName)
        }
        else {
            $addresses = [System.Net.Dns]::GetHostAddresses($HostName)
            $address = @($addresses | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork }) | Select-Object -First 1
            if (-not $address) { $address = @($addresses) | Select-Object -First 1 }
            if (-not $address) { throw "No IP address was returned for '$HostName'." }
        }
        $buffer = [byte[]]::new([int]$Settings.BufferSize)
        $options = [System.Net.NetworkInformation.PingOptions]::new([int]$Settings.Ttl, [bool]$Settings.DontFragment)
        $ping = [System.Net.NetworkInformation.Ping]::new()
        $phase = 'Ping'
        try {
            $pingStartedUtc = [DateTime]::UtcNow
            $reply = $ping.Send($address, [int]$Settings.Timeout, $buffer, $options)
            $Queue.Enqueue(@{
                    MonitorId = $MonitorId
                    AttemptId = $AttemptId
                    Status    = [string]$reply.Status
                    RttMs     = if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { [long]$reply.RoundtripTime } else { $null }
                    Address   = if ($reply.Address) { [string]$reply.Address } else { [string]$address }
                    Error     = $null
                    TimeoutMs = [int]$Settings.Timeout
                    Timestamp = $pingStartedUtc
                })
        }
        finally { if ($ping) { $ping.Dispose() } }
    }
    catch {
        $exception = $_.Exception
        while ($exception.InnerException) { $exception = $exception.InnerException }
        if (-not $pingStartedUtc) { $pingStartedUtc = $AttemptStartedUtc }
        $Queue.Enqueue(@{
                MonitorId = $MonitorId
                AttemptId = $AttemptId
                Status    = if ($phase -eq 'Resolve') { 'ResolveError' } else { 'Error' }
                RttMs     = $null
                Address   = if ($address) { [string]$address } else { $null }
                Error     = $exception.Message
                TimeoutMs = [int]$Settings.Timeout
                Timestamp = $pingStartedUtc
            })
    }
}
function Start-MonitorAttempt {
    param([Parameter(Mandatory)]$Monitor)
    if ($Monitor.IsStopping -or $Monitor.InFlight) { return $false }
    if ($script:RunningPingTasks -ge $script:Config.MaxConcurrentPings) { return $false }
    if ([DateTime]::UtcNow -lt $Monitor.NextDueUtc) { return $false }
    $settings = Get-CurrentPingSettings
    $attemptStartedUtc = [DateTime]::UtcNow
    $attemptId = ++$Monitor.AttemptId
    $Monitor.InFlight = $true
    $Monitor.NextDueUtc = $attemptStartedUtc.AddSeconds([double]$settings.Interval)
    $script:RunningPingTasks++
    $powerShell = [PowerShell]::Create()
    $powerShell.RunspacePool = $script:RunspacePool
    [void]$powerShell.AddScript($script:PingWorkerScript)
    [void]$powerShell.AddArgument($Monitor.Id)
    [void]$powerShell.AddArgument($Monitor.HostName)
    [void]$powerShell.AddArgument([bool]$Monitor.IsLiteralIp)
    [void]$powerShell.AddArgument($attemptId)
    [void]$powerShell.AddArgument($attemptStartedUtc)
    [void]$powerShell.AddArgument($settings)
    [void]$powerShell.AddArgument($script:UpdateQueue)
    try {
        $Monitor.PowerShell = $powerShell
        $Monitor.AsyncResult = $powerShell.BeginInvoke()
        return $true
    }
    catch {
        $Monitor.PowerShell = $null
        $Monitor.AsyncResult = $null
        $Monitor.InFlight = $false
        if ($script:RunningPingTasks -gt 0) { $script:RunningPingTasks-- }
        $Monitor.NextDueUtc = [DateTime]::UtcNow.AddSeconds([double]$settings.Interval)
        $powerShell.Dispose()
        $script:UpdateQueue.Enqueue(@{
                MonitorId = $Monitor.Id; AttemptId = $attemptId; Status = 'Error'; RttMs = $null
                Address   = $null; Error = $_.Exception.Message; TimeoutMs = [int]$settings.Timeout; Timestamp = $attemptStartedUtc
            })
        return $false
    }
}
function Complete-MonitorAttempt {
    param([Parameter(Mandatory)]$Monitor)
    if (-not $Monitor.InFlight -or -not $Monitor.AsyncResult) { return $false }
    if (-not $Monitor.AsyncResult.IsCompleted) { return $false }
    try { [void]$Monitor.PowerShell.EndInvoke($Monitor.AsyncResult) }
    catch { Write-Verbose "Monitor task '$($Monitor.HostName)' ended with: $($_.Exception.Message)" }
    finally {
        try { $Monitor.PowerShell.Dispose() } catch { Write-Verbose $_ }
        $Monitor.PowerShell = $null
        $Monitor.AsyncResult = $null
        $Monitor.InFlight = $false
        if ($script:RunningPingTasks -gt 0) { $script:RunningPingTasks-- }
    }
    return $true
}
function Complete-MonitorTasks {
    foreach ($monitor in @($script:Monitors.Values) + @($script:RetiredMonitors.Values)) {
        [void](Complete-MonitorAttempt -Monitor $monitor)
    }
    foreach ($id in @($script:RetiredMonitors.Keys)) {
        if (-not $script:RetiredMonitors[$id].InFlight) { $script:RetiredMonitors.Remove($id) }
    }
}
function Invoke-MonitorScheduler {
    Complete-MonitorTasks
    if ($script:RunningPingTasks -ge $script:Config.MaxConcurrentPings) { return }
    $now = [DateTime]::UtcNow
    foreach ($monitor in @($script:Monitors.Values | Sort-Object Sequence)) {
        if ($script:RunningPingTasks -ge $script:Config.MaxConcurrentPings) { break }
        if ($monitor.IsStopping -or $monitor.Paused -or $monitor.InFlight) { continue }
        if ($monitor.NextDueUtc -le $now) { [void](Start-MonitorAttempt -Monitor $monitor) }
    }
}
function Stop-PingEngine {
    foreach ($monitor in @($script:RetiredMonitors.Values)) {
        if ($monitor.PowerShell) {
            try { $monitor.PowerShell.Stop() } catch { Write-Verbose $_ }
            try { $monitor.PowerShell.Dispose() } catch { Write-Verbose $_ }
        }
    }
    $script:RetiredMonitors.Clear()
    try { $script:RunspacePool.Close(); $script:RunspacePool.Dispose() } catch { Write-Verbose $_ }
}
#endregion
#region 23.ViewModel.GlobalActions

$script:GlobalActionIcons = @{
    Reset = 'M960,0V213.333C1371.627,213.333 1706.667,548.267 1706.667,960S1371.627,1706.667 960,1706.667S213.333,1371.733 213.333,960C213.333,762.987 291.733,577.493 426.667,439.253V693.333H640V106.667H53.333V320H244.373C88.64,494.08 0,720.96 0,960C0,1489.28 430.613,1920 960,1920S1920,1489.28 1920,960S1489.387,0 960,0Z'
    Pause = 'M5,4 L10,4 L10,20 L5,20 Z M14,4 L19,4 L19,20 L14,20 Z'
    Resume = 'M7,4 L7,20 L20,12 Z'
    Clear = 'M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z'
}
function Invoke-GlobalAction {
    param([Parameter(Mandatory)][ValidateSet('Clear', 'Reset', 'PauseResume')][string]$Action)
    switch ($Action) {
        'Clear' { Clear-Monitors }
        'Reset' { foreach ($monitor in @($script:Monitors.Values)) { Reset-MonitorStatistics -Monitor $monitor } }
        'PauseResume' { Set-MonitorsPaused -Paused (-not $script:GlobalPaused) }
    }
    $script:LastGlobalAction = $Action
    Update-GlobalActionButton
}
function New-GlobalActionMenuItem {
    param([Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$IconData)
    $button = [System.Windows.Controls.Button]::new()
    $button.Style = $Window.FindResource('SplitMenuButtonStyle')
    $button.Tag = $Action
    $button.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    $button.HorizontalContentAlignment = [System.Windows.HorizontalAlignment]::Stretch
    $button.VerticalContentAlignment = [System.Windows.VerticalAlignment]::Center
    $grid = [System.Windows.Controls.Grid]::new()
    $grid.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    $grid.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $grid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]@{ Width = [System.Windows.GridLength]::new(20) })
    $grid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]@{ Width = [System.Windows.GridLength]::Auto })
    $icon = [System.Windows.Shapes.Path]::new()
    $icon.Data = [System.Windows.Media.Geometry]::Parse($IconData)
    $icon.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'Theme.MenuItem.IconFill')
    $icon.Width = 15; $icon.Height = 15
    $icon.Stretch = [System.Windows.Media.Stretch]::Uniform
    $icon.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    $icon.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.Grid]::SetColumn($icon, 0)
    [void]$grid.Children.Add($icon)
    $label = [System.Windows.Controls.TextBlock]::new()
    $label.Text = $Text
    if ($Action -eq 'PauseResume') { $script:GlobalPauseMenuLabel = $label }
    $label.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Theme.MenuItem.TextFill')
    $label.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.Grid]::SetColumn($label, 1)
    [void]$grid.Children.Add($label)
    $button.Content = $grid
    $button.Add_Click({
            param($sender, $e)
            $script:GlobalActionPopup.IsOpen = $false
            Invoke-GlobalAction -Action ([string]$sender.Tag)
            $e.Handled = $true
        })
    return $button
}
function Update-GlobalActionButton {
    if (-not $GlobalActionButton -or -not $GlobalActionIcon -or -not $GlobalActionText) { return }
    switch ($script:LastGlobalAction) {
        'Reset' {
            $label = 'Reset'; $tooltip = 'Reset all monitor statistics'; $iconData = $script:GlobalActionIcons.Reset
        }
        'PauseResume' {
            $label = if ($script:GlobalPaused) { 'Resume' } else { 'Pause' }
            $tooltip = if ($script:GlobalPaused) { 'Resume all monitors' } else { 'Pause all monitors' }
            $iconData = if ($script:GlobalPaused) { $script:GlobalActionIcons.Resume } else { $script:GlobalActionIcons.Pause }
        }
        default {
            $label = 'Clear'; $tooltip = 'Clear all monitors (F4)'; $iconData = $script:GlobalActionIcons.Clear
        }
    }
    $GlobalActionText.Text = $label
    $GlobalActionButton.ToolTip = $tooltip
    $GlobalActionIcon.Data = [System.Windows.Media.Geometry]::Parse($iconData)
    if ($script:GlobalPauseMenuLabel) { $script:GlobalPauseMenuLabel.Text = if ($script:GlobalPaused) { 'Resume' } else { 'Pause' } }
}
function Show-GlobalActionMenu {
    $script:GlobalActionSplitButtonBorder.UpdateLayout()
    $targetWidth = [Math]::Max(88.0, [double]$script:GlobalActionSplitButtonBorder.ActualWidth)
    $script:GlobalActionPopupBorder.MinWidth = $targetWidth
    $script:GlobalActionPopup.IsOpen = $true
}
function Initialize-GlobalActionSplitButton {
    $script:GlobalActionSplitButtonBorder = $Window.FindName('GlobalActionSplitButton')
    $script:GlobalActionButton = $Window.FindName('GlobalActionButton')
    $script:GlobalActionArrowButton = $Window.FindName('GlobalActionArrowButton')
            $popup = [System.Windows.Controls.Primitives.Popup]::new()
    $popup.AllowsTransparency = $true
    $popup.StaysOpen = $false
    $popup.PlacementTarget = $script:GlobalActionSplitButtonBorder
    $popup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    $popup.VerticalOffset = 3
    $outer = [System.Windows.Controls.Border]::new()
    $outer.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'Theme.Popup.Background')
    $outer.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Theme.Popup.Border')
    $outer.BorderThickness = [System.Windows.Thickness]::new(1)
    $outer.CornerRadius = [System.Windows.CornerRadius]::new(7)
    $outer.Padding = [System.Windows.Thickness]::new(3)
    $shadow = [System.Windows.Media.Effects.DropShadowEffect]::new()
    $shadow.BlurRadius = 12; $shadow.ShadowDepth = 2; $shadow.Opacity = 0.12
    $outer.Effect = $shadow
    $panel = [System.Windows.Controls.StackPanel]::new()
    $resetItem = New-GlobalActionMenuItem -Action 'Reset' -Text 'Reset' -IconData $script:GlobalActionIcons.Reset
    $pauseItem = New-GlobalActionMenuItem -Action 'PauseResume' -Text 'Pause' -IconData $script:GlobalActionIcons.Pause
    $clearItem = New-GlobalActionMenuItem -Action 'Clear' -Text 'Clear' -IconData $script:GlobalActionIcons.Clear
    $panel.Children.Add($resetItem) | Out-Null
    $panel.Children.Add($pauseItem) | Out-Null
    $panel.Children.Add($clearItem) | Out-Null
    $outer.Child = $panel
    $popup.Child = $outer
    $popup.Tag = $pauseItem
    $script:GlobalActionPopup = $popup
    $script:GlobalActionPopupBorder = $outer
    $script:GlobalActionArrowButton.Add_Click({
            if ($script:GlobalActionPopup.IsOpen) { $script:GlobalActionPopup.IsOpen = $false }
            else { Show-GlobalActionMenu }
        })
    $script:GlobalActionButton.Add_Click({ $script:GlobalActionPopup.IsOpen = $false; Invoke-GlobalAction -Action $script:LastGlobalAction })
    Update-GlobalActionButton
}
#endregion
#region 24.ViewModel.Configuration

function Set-MonitoringSettings {
    param(
        [Parameter(Mandatory)][int]$Interval,
        [Parameter(Mandatory)][int]$Timeout,
        [Parameter(Mandatory)][int]$BufferSize,
        [Parameter(Mandatory)][int]$HistoryDepth,
        [Parameter(Mandatory)][int]$Ttl,
        [Parameter(Mandatory)][bool]$DontFragment
    )
    $historyDepthChanged = $script:Settings.HistoryDepth -ne $HistoryDepth
    $script:Settings = [pscustomobject]@{
        Interval = $Interval; Timeout = $Timeout; BufferSize = $BufferSize
        HistoryDepth = $HistoryDepth; Ttl = $Ttl; DontFragment = $DontFragment
    }
    if ($historyDepthChanged) {
        foreach ($monitor in @($script:Monitors.Values)) { Set-MonitorGraphBarWidth -Monitor $monitor }
    }
    $now = [DateTime]::UtcNow
    foreach ($monitor in @($script:Monitors.Values)) {
        if (-not $monitor.InFlight) { $monitor.NextDueUtc = $now }
    }
}
function Save-Configuration {
    $config = [ordered]@{
        HostList     = @(Get-MonitorNames)
        OnTop        = [bool]$Window.Topmost
        AutoSaveOnExit= [bool]$script:AutoSaveOnExit
        HistoryDepth = [int]$script:Settings.HistoryDepth
        Timeout      = [int]$script:Settings.Timeout
        Interval     = [int]$script:Settings.Interval
        BufferSize   = [int]$script:Settings.BufferSize
        Ttl          = [int]$script:Settings.Ttl
        DontFragment = [bool]$script:Settings.DontFragment
        Theme        = [string]$script:ThemeName
        ViewMode     = [string]$script:ViewMode
        WindowWidth  = [double]$Window.Width
        WindowHeight = [double]$Window.Height
    }
    $json = $config | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllText($script:ConfigPath, $json, [System.Text.UTF8Encoding]::new($false))
    Set-StatusText "Saved configuration to $($script:ConfigPath)"
}
function Read-Configuration {
    if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json) }
    catch {
        Write-Verbose "The configuration could not be parsed: $($_.Exception.Message)"
        return $null
    }
}
function Apply-Configuration {
    param([Parameter(Mandatory)]$ConfigData)
    $clamp = { param($value, $min, $max, $fallback) if ($null -ne $value) { [Math]::Max($min, [Math]::Min($max, [int]$value)) } else { $fallback } }
    $newInterval     = & $clamp $ConfigData.Interval 0 3600 ([int]$script:Settings.Interval)
    $newBuffer       = & $clamp $ConfigData.BufferSize 0 65500 ([int]$script:Settings.BufferSize)
    $newHistoryDepth = & $clamp $ConfigData.HistoryDepth 0 20 ([int]$script:Settings.HistoryDepth)
    $newTtl          = & $clamp $ConfigData.Ttl 1 255 ([int]$script:Settings.Ttl)
    $newTimeout      = if ($null -ne $ConfigData.Timeout) { [Math]::Max(1, [int]$ConfigData.Timeout) } else { [int]$script:Settings.Timeout }
    $newDontFragment = if ($null -ne $ConfigData.DontFragment) { [bool]$ConfigData.DontFragment } else { [bool]$script:Settings.DontFragment }
    Set-MonitoringSettings -Interval $newInterval -Timeout $newTimeout -BufferSize $newBuffer -HistoryDepth $newHistoryDepth -Ttl $newTtl -DontFragment $newDontFragment
    if ($null -ne $ConfigData.OnTop) { $Window.Topmost = [bool]$ConfigData.OnTop }
    if ($null -ne $ConfigData.AutoSaveOnExit) { $script:AutoSaveOnExit = [bool]$ConfigData.AutoSaveOnExit }
    if ($ConfigData.Theme) { [void](Set-AppTheme -ThemeName ([string]$ConfigData.Theme)) }
    if ($ConfigData.ViewMode -and @('Card', 'Table') -contains [string]$ConfigData.ViewMode) { Set-ViewMode -Mode ([string]$ConfigData.ViewMode) }
    if ($null -ne $ConfigData.WindowWidth) { $Window.Width = [Math]::Max($Window.MinWidth, [double]$ConfigData.WindowWidth) }
    if ($null -ne $ConfigData.WindowHeight) { $Window.Height = [Math]::Max($Window.MinHeight, [double]$ConfigData.WindowHeight) }
    Clear-Monitors
    foreach ($hostName in @($ConfigData.HostList | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) ) { [void](Add-Monitor -HostName ([string]$hostName)) }
    Set-StatusText "Loaded configuration from $($script:ConfigPath)"
}
function Load-Configuration {
    $config = Read-Configuration
    if ($config) { Apply-Configuration -ConfigData $config; $script:LoadedConfiguration = $config }
    elseif (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf) { Show-MessageBox -Message "The configuration could not be loaded." -Title 'Configuration error' -Icon Error }
}
#endregion
if ($ExternalInvocation -or $HideConsole) { Set-ConsoleWindowState -State hidden }
$script:ConfigPath          = Get-ConfigPath
$script:AutoSaveOnExit     = $false
$script:LoadedConfiguration = Read-Configuration
$script:Sequence            = 0
$script:DraggingCard        = $null
$script:DropIndicator       = $null
$script:DropIndicatorOverlay= $null
$script:DraggingRow         = $null
$script:DraggedMonitor      = $null
$script:ViewMode            = 'Card'
$script:GlobalPaused        = $false
$script:LastGlobalAction    = 'Clear'
$script:GlobalActionPopup   = $null
$script:Settings            = New-DefaultSettings -Interval $Interval -Timeout $Timeout -BufferSize $BufferSize -HistoryDepth $HistoryDepth
$script:Monitors            = @{}
$script:RetiredMonitors     = @{}
Initialize-PingEngine
$configuredTheme = if ($script:ThemeRegistry.Contains([string]$script:LoadedConfiguration.Theme)) { [string]$script:LoadedConfiguration.Theme } else { $Theme }
$script:ThemeName   = $configuredTheme
$script:EffectiveThemeName = if ($configuredTheme -eq 'System') { Get-SystemThemeName } else { $configuredTheme }
$script:ThemeColors = & $script:ThemeRegistry[$script:ThemeName]
$script:AppResources = New-AppResources -Colors $script:ThemeColors -ThemeName $script:EffectiveThemeName
$cardForSizing = Read-XamlWindow -Xaml ([xml]$script:MonitorCardXaml) -ResourceDict $script:AppResources
$cardForSizing.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
$script:MonitorCardFootprint = $cardForSizing.DesiredSize
$script:PreCompactHeight = $null
$script:CustomWindowChrome = New-CustomWindowChrome
$windowIcon = New-AppIconSource
[xml]$mainXaml = $script:MainWindowXaml
$Window = Read-XamlWindow -Xaml $mainXaml -ResourceDict $script:AppResources
[System.Windows.Shell.WindowChrome]::SetWindowChrome($Window, $script:CustomWindowChrome)
$Window.Topmost = [bool]$OnTop
$Window.Icon = $windowIcon
$LogoViewBox             = $Window.FindName('LogoViewBox')
$HostInput               = $Window.FindName('HostInput')
$InputHint               = $Window.FindName('InputHint')
$AddButton               = $Window.FindName('AddButton')
$MonitorScroll           = $Window.FindName('MonitorScroll')
$MonitorPanel            = $Window.FindName('MonitorPanel')
$StatusText              = $Window.FindName('StatusText')
$LoadButton              = $Window.FindName('LoadButton')
$SaveButton              = $Window.FindName('SaveButton')
$OptionsButton           = $Window.FindName('OptionsButton')
$ToolbarPanel            = $Window.FindName('ToolbarPanel')
$HostInputPanel          = $Window.FindName('HostInputPanel')
$StatusBar               = $Window.FindName('StatusBar')
$ModeToggleButton        = $Window.FindName('ModeToggleButton')
$GlobalActionButton      = $Window.FindName('GlobalActionButton')
$GlobalActionArrowButton = $Window.FindName('GlobalActionArrowButton')
$GlobalActionIcon        = $Window.FindName('GlobalActionIcon')
$GlobalActionText        = $Window.FindName('GlobalActionText')
$TitleCloseButton        = $Window.FindName('TitleCloseButton')
$TitleMinimizeButton     = $Window.FindName('TitleMinimizeButton')
$TitleMaximizeButton     = $Window.FindName('TitleMaximizeButton')
$DropIndicatorOverlay    = $Window.FindName('DropIndicatorOverlay')
$CardViewContainer       = $Window.FindName('CardViewContainer')
$ContentGrid             = $Window.FindName('ContentGrid')
$TableViewContainer      = $Window.FindName('TableViewContainer')
$TableGrid               = $Window.FindName('TableGrid')
$TableDragOverlay        = $Window.FindName('TableDragOverlay')
$TableDropLine           = $Window.FindName('TableDropLine')
$ModalOverlay            = $Window.FindName('ModalOverlay')
$ViewToggleButton        = $Window.FindName('ViewToggleButton')
$ViewToggleIcon          = $Window.FindName('ViewToggleIcon')
$ViewToggleText          = $Window.FindName('ViewToggleText')
$LogoViewBox.Child = New-AppLogoVisual
$Window.FindName('TitleLogoBox').Child = New-AppLogoVisual
$LogoViewBox.Visibility = if ($script:Monitors.Count) { 'Collapsed' } else { 'Visible' }
$script:DropIndicatorOverlay = $DropIndicatorOverlay
$MonitorScroll.Background = [System.Windows.Media.Brushes]::Transparent
$TableGrid.Background = [System.Windows.Media.Brushes]::Transparent
Initialize-DataGridActions
Initialize-DataGridDragDrop
$HostInput.Add_TextChanged({ $InputHint.Visibility = if ($HostInput.Text.Length) { 'Collapsed' } else { 'Visible' } })
$AddButton.Add_Click({ [void](Add-Monitor -HostName $HostInput.Text) })
$LoadButton.Add_Click({ Load-Configuration })
$SaveButton.Add_Click({
        try { Save-Configuration }
        catch { Show-MessageBox -Message "The configuration could not be saved.`n`n$($_.Exception.Message)" -Title 'Save error' -Icon Error }
    })
$OptionsButton.Add_Click({ Show-OptionsWindow })
$ViewToggleButton.Add_Click({
        $nextMode = if ($script:ViewMode -eq 'Card') { 'Table' } else { 'Card' }
        Set-ViewMode -Mode $nextMode
    })
Initialize-GlobalActionSplitButton
Register-DropTarget -Element $MonitorPanel
Register-DropTarget -Element $MonitorScroll
$TitleCloseButton.Add_Click({ $Window.Close() })
$TitleMinimizeButton.Add_Click({ [System.Windows.SystemCommands]::MinimizeWindow($Window) })
$TitleMaximizeButton.Add_Click({
        if ($Window.WindowState -eq 'Maximized') { [System.Windows.SystemCommands]::RestoreWindow($Window) }
        else { [System.Windows.SystemCommands]::MaximizeWindow($Window) }
    })
$Window.Add_StateChanged({
        if ($Window.WindowState -eq 'Maximized') {
            $TitleMaximizeButton.Content = [char]0xE923; $TitleMaximizeButton.ToolTip = 'Restore'
        }
        else {
            $TitleMaximizeButton.Content = [char]0xE922; $TitleMaximizeButton.ToolTip = 'Maximize'
        }
    })
$ModeToggleButton.Add_Click({ Set-WindowMode -Mode $(if ($ToolbarPanel.Visibility -eq 'Visible') { 'Compact' } else { 'Standard' }) })
$Window.Add_KeyDown({
        param($sender, $e)
        $ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
        if ($e.Key -eq [System.Windows.Input.Key]::F9) {
            Set-WindowMode -Mode $(if ($ToolbarPanel.Visibility -eq 'Visible') { 'Compact' } else { 'Standard' })
            $e.Handled = $true
        }
        elseif ($e.Key -eq [System.Windows.Input.Key]::F2) {
            Load-Configuration
            $e.Handled = $true
        }
        elseif ($e.Key -eq [System.Windows.Input.Key]::F3 -or ($e.Key -eq [System.Windows.Input.Key]::S -and $ctrl)) {
            Save-Configuration
            $e.Handled = $true
        }
        elseif ($e.Key -eq [System.Windows.Input.Key]::F8) {
            $nextMode = if ($script:ViewMode -eq 'Card') { 'Table' } else { 'Card' }
            Set-ViewMode -Mode $nextMode
            $e.Handled = $true
        }
        elseif ($e.Key -eq [System.Windows.Input.Key]::F4) {
            Invoke-GlobalAction -Action 'Clear'
            $e.Handled = $true
        }
        elseif ($e.Key -eq [System.Windows.Input.Key]::OemComma -and $ctrl) {
            Show-OptionsWindow
            $e.Handled = $true
        }
        elseif ($e.Key -eq [System.Windows.Input.Key]::Escape) {
            $HostInput.Clear()
            $e.Handled = $true
        }
    })
$updateTimer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Background)
$updateTimer.Interval = [TimeSpan]::FromMilliseconds(50)
$updateTimer.Add_Tick({
        $result = $null
        $processed = 0
        while ($processed -lt 200 -and $script:UpdateQueue.TryDequeue([ref]$result)) {
            Update-MonitorCard -Result $result
            if ($script:Monitors.ContainsKey([string]$result.MonitorId)) {
                Update-MonitorRow -Monitor $script:Monitors[[string]$result.MonitorId] -Result $result
            }
            $result = $null
            $processed++
        }
        if ($processed -gt 0) { $TableGrid.Items.Refresh() }
        Invoke-MonitorScheduler
    })
$Window.Add_ContentRendered({
        $Window.UpdateLayout()
        Update-WindowMinSize
        $HostInput.Focus()
    })
$Window.Add_SizeChanged({
        $labelsVisible = if ($Window.ActualWidth -lt $script:Config.ToolbarLabelWidthBreak) { 'Collapsed' } else { 'Visible' }
        foreach ($btn in $LoadButton, $SaveButton, $OptionsButton, $ViewToggleButton) {
            if ($btn.Content -is [System.Windows.Controls.StackPanel] -and $btn.Content.Children.Count -gt 1) {
                $btn.Content.Children[1].Visibility = $labelsVisible
            }
        }
        if ($GlobalActionText) { $GlobalActionText.Visibility = $labelsVisible }
    })
$Window.Add_Closing({
        if ($script:AutoSaveOnExit) {
            try { Save-Configuration }
            catch { Write-Verbose "Auto-save on exit failed: $($_.Exception.Message)" }
        }
        $updateTimer.Stop()
        foreach ($monitor in @($script:Monitors.Values)) {
            $monitor.IsStopping = $true
            $script:RetiredMonitors[$monitor.Id] = $monitor
        }
        $script:Monitors.Clear()
        $MonitorPanel.Children.Clear()
        $TableGrid.Items.Clear()
        foreach ($monitor in @($script:RetiredMonitors.Values)) {
            try {
                if ($monitor.InFlight -and $monitor.PowerShell -and -not $monitor.AsyncResult.IsCompleted) {
                    [void]$monitor.PowerShell.BeginStop($null, $null)
                }
            }
            catch { Write-Verbose "BeginStop failed for '$($monitor.HostName)': $_" }
        }
        Unregister-SystemThemeWatcher
        Set-ConsoleWindowState -State restored
    })
Register-SystemThemeWatcher
if ($script:LoadedConfiguration) { Apply-Configuration -ConfigData $script:LoadedConfiguration }
$Window.UpdateLayout()
$updateTimer.Start()
[void]$Window.ShowDialog()
Stop-PingEngine
