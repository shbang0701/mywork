# 공통 부품. 버튼 · 입력 칸 · 카드 · 메뉴 항목 같은 모양은 여기서만 정한다.
# 기능(애드온) 모듈은 아래 New-Wt* 함수와 스타일 이름만 쓰고, 색 값이나 글꼴 이름을 직접 쓰지 않는다.
# 색 · 크기는 Theme.psm1의 리소스(B.* · F.* · Font.*)를 DynamicResource로 참조해서, 테마를 바꾸면 바로 반영된다.

$ErrorActionPreference = 'Stop'

$script:ns = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'
$script:targetRows = [System.Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()

# 스타일 모음. 색은 Style.Triggers에서 바꾼다 (템플릿 트리거로 바꾸면 BasedOn 스타일에서 덮어쓸 수 없어서).
$script:stylesXaml = @'
<ResourceDictionary {NS} xmlns:sys="clr-namespace:System;assembly=mscorlib">

  <!-- 창 짜임 전용 치수: 디자인 2판 6·8절. Theme의 공통 토큰과 분리한다. -->
  <sys:Double x:Key="F.Chrome.Height">32</sys:Double>
  <sys:Double x:Key="F.Nav.Width">200</sys:Double>
  <sys:Double x:Key="F.Nav.CollapsedWidth">48</sys:Double>
  <sys:Double x:Key="F.SidePanel.RailWidth">28</sys:Double>
  <sys:Double x:Key="F.SidePanel.Gap">8</sys:Double>
  <sys:Double x:Key="F.SidePanel.Breakpoint">1200</sys:Double>
  <Style x:Key="Shell.Window" TargetType="Window">
    <Setter Property="Width" Value="1280"/><Setter Property="Height" Value="800"/>
    <Setter Property="MinWidth" Value="1024"/><Setter Property="MinHeight" Value="640"/>
  </Style>
  <Style x:Key="Shell.Brand" TargetType="Border">
    <Setter Property="Width" Value="16"/><Setter Property="Height" Value="16"/>
    <Setter Property="CornerRadius" Value="4"/><Setter Property="Margin" Value="12,0,0,0"/>
    <Setter Property="VerticalAlignment" Value="Center"/>
    <Setter Property="Background" Value="{DynamicResource B.Accent}"/>
  </Style>
  <Style x:Key="Shell.BrandLetter" TargetType="TextBlock">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="10"/><Setter Property="FontWeight" Value="Bold"/>
    <Setter Property="Foreground" Value="{DynamicResource B.OnAccent}"/>
    <Setter Property="HorizontalAlignment" Value="Center"/><Setter Property="VerticalAlignment" Value="Center"/>
  </Style>

  <!-- 키보드 포커스: 바깥 2 + 안쪽 1, 요소에서 1 띄움. 행은 안쪽에 그린다. -->
  <Style x:Key="Focus.Outside" TargetType="Control">
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Control">
      <Grid Margin="-4" IsHitTestVisible="False">
        <Border BorderBrush="{DynamicResource B.Text.Primary}" BorderThickness="2" CornerRadius="4"/>
        <Border Margin="2" BorderBrush="{DynamicResource B.Bg.Surface}" BorderThickness="1" CornerRadius="2"/>
      </Grid>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Focus.Inside" TargetType="Control">
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Control">
      <Grid Margin="1" IsHitTestVisible="False">
        <Border BorderBrush="{DynamicResource B.Text.Primary}" BorderThickness="2"/>
        <Border Margin="2" BorderBrush="{DynamicResource B.Bg.Surface}" BorderThickness="1"/>
      </Grid>
    </ControlTemplate></Setter.Value></Setter>
  </Style>


  <Style x:Key="T.Body" TargetType="TextBlock">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Body.Weight}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.Body.LineHeight}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/>
    <Setter Property="TextWrapping" Value="Wrap"/>

  </Style>
  <Style x:Key="T.Sub" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontSize" Value="{DynamicResource F.Caption}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Caption.Weight}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.Caption.LineHeight}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Secondary}"/>

  </Style>
  <Style x:Key="T.Title" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontSize" Value="{DynamicResource F.Title}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Title.Weight}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.Title.LineHeight}"/>

  </Style>
  <Style x:Key="T.Display" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontSize" Value="{DynamicResource F.Display}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Display.Weight}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.Display.LineHeight}"/>
  </Style>
  <Style x:Key="T.H2" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontSize" Value="{DynamicResource F.BodyStrong}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.BodyStrong.Weight}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.BodyStrong.LineHeight}"/>

  </Style>
  <Style x:Key="T.Number" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontSize" Value="{DynamicResource F.Title}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Title.Weight}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.Title.LineHeight}"/>

  </Style>
  <Style x:Key="T.Dialog" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontSize" Value="{DynamicResource F.Subtitle}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Subtitle.Weight}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.Subtitle.LineHeight}"/>

  </Style>
  <Style x:Key="T.Strong" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontSize" Value="{DynamicResource F.BodyStrong}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.BodyStrong.Weight}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.BodyStrong.LineHeight}"/>

  </Style>
  <Style x:Key="T.Icon" TargetType="TextBlock">
    <Setter Property="FontFamily" Value="{DynamicResource Font.Icon}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Icon}"/>
    <Setter Property="VerticalAlignment" Value="Center"/>
    <Setter Property="HorizontalAlignment" Value="Center"/>
  </Style>

  <Style x:Key="Card" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource B.Bg.Surface}"/>
    <Setter Property="CornerRadius" Value="{DynamicResource F.Radius.Card}"/>
    <Setter Property="Padding" Value="{DynamicResource F.Padding.Card}"/>
  </Style>
  <Style x:Key="Panel.Surface" TargetType="Border" BasedOn="{StaticResource Card}">
    <Setter Property="Padding" Value="0"/>
  </Style>
  <Style x:Key="Tile" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource B.Bg.Subtle}"/>
    <Setter Property="CornerRadius" Value="{DynamicResource F.Radius.Control}"/>
    <Setter Property="Padding" Value="{DynamicResource F.Padding.Panel}"/>

  </Style>
  <Style x:Key="Divider" TargetType="Border">
    <Setter Property="BorderBrush" Value="{DynamicResource B.Divider}"/>
    <Setter Property="BorderThickness" Value="0,1,0,0"/>
  </Style>

  <Style x:Key="Btn" TargetType="Button">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Body.Weight}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/>
    <Setter Property="Background" Value="{DynamicResource B.Bg.Surface}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Strong}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="12,0"/>
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.Control}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Outside}"/>
    <Setter Property="ToolTipService.ShowOnDisabled" Value="True"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="{DynamicResource F.Radius.Control}" Padding="{TemplateBinding Padding}">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="False"/>
      </Border>
    </ControlTemplate></Setter.Value></Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/>
      </Trigger>
      <Trigger Property="IsPressed" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Pressed.Surface}"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False">
        <Setter Property="Background" Value="{DynamicResource B.Bg.Canvas}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/>
    <Setter Property="Opacity" Value="1"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Btn.Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Background" Value="{DynamicResource B.Accent}"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Foreground" Value="{DynamicResource B.OnAccent}"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Accent.Hover}"/>
      </Trigger>
      <Trigger Property="IsPressed" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Accent.Pressed}"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False">
        <Setter Property="Background" Value="{DynamicResource B.Bg.Canvas}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/>
    <Setter Property="Opacity" Value="1"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Btn.Danger" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Status.Error.Text}"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/>
      </Trigger>
      <Trigger Property="IsPressed" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Pressed.Surface}"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="BorderBrush" Value="Transparent"/>
        <Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/>
        <Setter Property="Opacity" Value="1"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Btn.Link" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Accent.Text}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Caption}"/>
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.Compact}"/>
    <Setter Property="Padding" Value="12,0"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/>
      </Trigger>
      <Trigger Property="IsPressed" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Pressed.Surface}"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="BorderBrush" Value="Transparent"/>
        <Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/>
        <Setter Property="Opacity" Value="1"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Btn.Icon" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Secondary}"/>
    <Setter Property="Width" Value="{DynamicResource F.Height.Compact}"/>
    <Setter Property="Height" Value="{DynamicResource F.Height.Compact}"/>
    <Setter Property="MinHeight" Value="0"/>
    <Setter Property="Padding" Value="0"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/>
      </Trigger>
      <Trigger Property="IsPressed" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Pressed.Surface}"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="BorderBrush" Value="Transparent"/>
        <Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/>
        <Setter Property="Opacity" Value="1"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Btn.Chrome" TargetType="Button" BasedOn="{StaticResource Btn.Icon}">
    <Setter Property="Width" Value="46"/>
    <Setter Property="Height" Value="{DynamicResource F.Height.Control}"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Canvas}"/>
      </Trigger>
      <Trigger Property="IsPressed" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Pressed.Canvas}"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False">
        <Setter Property="Background" Value="{DynamicResource B.Bg.Canvas}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/>
    <Setter Property="Opacity" Value="1"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Btn.Canvas" TargetType="Button" BasedOn="{StaticResource Btn.Icon}">
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Canvas}"/></Trigger>
      <Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="{DynamicResource B.Fill.Pressed.Canvas}"/></Trigger>
      <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Btn.NavFooter" TargetType="Button" BasedOn="{StaticResource Btn.Canvas}">
    <Setter Property="Width" Value="32"/><Setter Property="Height" Value="32"/>
  </Style>
  <Style x:Key="T.NavGroup" TargetType="TextBlock" BasedOn="{StaticResource T.Sub}">
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Tertiary}"/>
    <Setter Property="Height" Value="24"/><Setter Property="Margin" Value="12,0,0,0"/>
    <Setter Property="VerticalAlignment" Value="Center"/>
  </Style>
  <Style x:Key="T.NavCount" TargetType="TextBlock" BasedOn="{StaticResource T.Sub}">
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Tertiary}"/>
    <Setter Property="VerticalAlignment" Value="Center"/>
    <Setter Property="HorizontalAlignment" Value="Right"/>
    <Setter Property="TextWrapping" Value="NoWrap"/>
  </Style>
  <Style x:Key="T.NavIcon" TargetType="TextBlock" BasedOn="{StaticResource T.Icon}">
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Secondary}"/>
  </Style>
  <Style x:Key="T.NavGroup.Next" TargetType="TextBlock" BasedOn="{StaticResource T.NavGroup}">
    <Setter Property="Margin" Value="12,12,0,0"/>
  </Style>
  <Style x:Key="Nav.Dot" TargetType="Ellipse">
    <Setter Property="Width" Value="6"/><Setter Property="Height" Value="6"/>
    <Setter Property="Fill" Value="{DynamicResource B.Status.Warning.Icon}"/>
    <Setter Property="VerticalAlignment" Value="Center"/><Setter Property="HorizontalAlignment" Value="Right"/>
    <Setter Property="Visibility" Value="Collapsed"/>
  </Style>
  <DataTemplate x:Key="Shell.NavItem">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <Grid Width="16" Height="16" VerticalAlignment="Center">
        <TextBlock x:Name="Icon" Style="{DynamicResource T.NavIcon}"/>
        <Ellipse x:Name="IconDot" Style="{DynamicResource Nav.Dot}" VerticalAlignment="Top" Margin="0,-4,-4,0"/>
      </Grid>
      <TextBlock x:Name="Label" Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="Count" Grid.Column="2" Style="{DynamicResource T.NavCount}"/>
      <Ellipse x:Name="Dot" Grid.Column="2" Style="{DynamicResource Nav.Dot}"/>
    </Grid>
  </DataTemplate>
  <DataTemplate x:Key="Shell.SidePanel">
    <Grid Panel.ZIndex="1">
      <Border x:Name="Expanded" Background="{DynamicResource B.Bg.Surface}" BorderBrush="{DynamicResource B.Border.Default}" CornerRadius="{DynamicResource F.Radius.Card}">
        <DockPanel>
          <DockPanel x:Name="Header" DockPanel.Dock="Top" Height="{DynamicResource F.Height.Header}" LastChildFill="True" Margin="8,0,8,0">
            <Button x:Name="Collapse" DockPanel.Dock="Left" Style="{DynamicResource Btn.Icon}" VerticalAlignment="Center">
              <TextBlock x:Name="CollapseGlyph" Style="{DynamicResource T.Icon}"/>
            </Button>
            <TextBlock x:Name="Title" Style="{DynamicResource T.Dialog}" Margin="4,0,0,0" VerticalAlignment="Center" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
          </DockPanel>
          <ContentControl x:Name="Content" Focusable="False"/>
        </DockPanel>
      </Border>
      <Border x:Name="Rail" Width="{DynamicResource F.SidePanel.RailWidth}" Background="{DynamicResource B.Bg.Surface}" CornerRadius="{DynamicResource F.Radius.Card}">
        <Grid Height="{DynamicResource F.Height.Header}" VerticalAlignment="Top">
          <Button x:Name="Open" Style="{DynamicResource Btn.Icon}" VerticalAlignment="Center">
            <TextBlock x:Name="OpenGlyph" Style="{DynamicResource T.Icon}"/>
          </Button>
        </Grid>
      </Border>
    </Grid>
  </DataTemplate>
  <Style x:Key="Btn.Close" TargetType="Button" BasedOn="{StaticResource Btn.Chrome}">


  </Style>

  <Style x:Key="Nav" TargetType="RadioButton">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Height" Value="{DynamicResource F.Height.Control}"/>
    <Setter Property="Margin" Value="0"/>
    <Setter Property="Padding" Value="12,0,8,0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Inside}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
      <Grid>
        <Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}"><ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="False"/></Border>
        <Border x:Name="SelectedBar" Width="3" Height="16" CornerRadius="1.5" Background="{DynamicResource B.Accent}" HorizontalAlignment="Left" VerticalAlignment="Center" Visibility="Collapsed"/>
      </Grid>
      <ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="SelectedBar" Property="Visibility" Value="Visible"/></Trigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Canvas}"/>
      </Trigger>
      <Trigger Property="IsPressed" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Pressed.Canvas}"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False">
        <Setter Property="Background" Value="{DynamicResource B.Bg.Canvas}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/>
    <Setter Property="Opacity" Value="1"/>
      </Trigger>
      <Trigger Property="IsChecked" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Selected.Nav}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.BodyStrong.Weight}"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style x:Key="Seg" TargetType="RadioButton">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.Compact}"/>
    <Setter Property="Padding" Value="12,0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Outside}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton"><Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="False"/></Border></ControlTemplate></Setter.Value></Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/>
      </Trigger>
      <Trigger Property="IsPressed" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Pressed.Surface}"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False">
        <Setter Property="Background" Value="{DynamicResource B.Bg.Canvas}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/>
    <Setter Property="Opacity" Value="1"/>
      </Trigger>
      <Trigger Property="IsChecked" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Bg.Selected}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style x:Key="Swatch" TargetType="RadioButton">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/>
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.Control}"/>
    <Setter Property="Margin" Value="0,0,8,0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Outside}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
      <Border x:Name="Bd" Background="{DynamicResource B.Bg.Surface}" BorderBrush="{DynamicResource B.Border.Strong}" BorderThickness="1" CornerRadius="4" Padding="8,0">
        <DockPanel>
          <Border DockPanel.Dock="Left" Width="16" Height="16" CornerRadius="2" Background="{TemplateBinding Background}" VerticalAlignment="Center"/>
          <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="False"/>
        </DockPanel>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.Fill.Pressed.Surface}"/></Trigger>
        <Trigger Property="IsChecked" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource B.Accent}"/><Setter TargetName="Bd" Property="BorderThickness" Value="2"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/><Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.Bg.Canvas}"/><Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>

  <Style x:Key="Input" TargetType="TextBox">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/>
    <Setter Property="Background" Value="{DynamicResource B.Bg.Surface}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Control}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="10,0"/>
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.Control}"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="TextBlock.LineHeight" Value="{DynamicResource F.Body.LineHeight}"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Outside}"/>
    <Setter Property="ToolTipService.ShowOnDisabled" Value="True"/>
    <Setter Property="Validation.ErrorTemplate" Value="{x:Null}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox">
      <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
        <Grid>
          <ScrollViewer x:Name="PART_ContentHost" Focusable="False" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
          <TextBlock x:Name="ErrorIcon" Text="&#xEB90;" FontFamily="{DynamicResource Font.Icon}" FontSize="16" Foreground="{DynamicResource B.Status.Error.Icon}" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0" Visibility="Collapsed"/>
        </Grid>
      </Border>
      <ControlTemplate.Triggers><Trigger Property="Validation.HasError" Value="True"><Setter TargetName="ErrorIcon" Property="Visibility" Value="Visible"/></Trigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
    <Style.Triggers>
      <Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/><Setter Property="BorderThickness" Value="2"/></Trigger>
      <Trigger Property="Validation.HasError" Value="True"><Setter Property="BorderBrush" Value="{DynamicResource B.Status.Error.Icon}"/><Setter Property="Padding" Value="10,0,32,0"/><Setter Property="ToolTip" Value="{Binding RelativeSource={RelativeSource Self}, Path=(Validation.Errors)[0].ErrorContent}"/></Trigger>
      <Trigger Property="IsEnabled" Value="False"><Setter Property="Background" Value="{DynamicResource B.Bg.Canvas}"/><Setter Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/><Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/><Setter Property="Opacity" Value="1"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Reader" TargetType="TextBox" BasedOn="{StaticResource Input}">
    <Setter Property="IsReadOnly" Value="True"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Padding" Value="0"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
    <Setter Property="AcceptsReturn" Value="True"/>
    <Setter Property="VerticalContentAlignment" Value="Top"/>
    <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Style.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="BorderThickness" Value="0"/></Trigger></Style.Triggers>
  </Style>
  <!-- 실행 출력: 코드 바탕의 읽기 전용 여러 줄. 줄을 바꾸지 않고 가로로 스크롤한다 (스크립트 출력 등) -->
  <Style x:Key="Output" TargetType="TextBox" BasedOn="{StaticResource Input}">
    <Setter Property="IsReadOnly" Value="True"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Background" Value="{DynamicResource B.Code.Bg}"/>
    <Setter Property="FontFamily" Value="{DynamicResource Font.Mono}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Code.Dense}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Default}"/>
    <Setter Property="TextBlock.LineHeight" Value="{DynamicResource F.Code.Dense.LineHeight}"/>
    <Setter Property="Padding" Value="12"/>
    <Setter Property="TextWrapping" Value="NoWrap"/>
    <Setter Property="AcceptsReturn" Value="True"/>
    <Setter Property="VerticalContentAlignment" Value="Top"/>
    <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
    <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
  </Style>

  <!-- 고르기 칸(ComboBox): 입력칸과 같은 테두리 · 높이 · 모서리. 펼친 목록은 카드 모양 -->
  <Style x:Key="Combo.Item" TargetType="ComboBoxItem">
    <Setter Property="Padding" Value="12,0"/>
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.Control}"/>
    <Setter Property="Background" Value="{DynamicResource B.Bg.Surface}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Inside}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem">
      <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"><ContentPresenter VerticalAlignment="Center"/></Border>
    </ControlTemplate></Setter.Value></Setter>
    <Style.Triggers>
      <Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/></Trigger>
      <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource B.Bg.Selected}"/></Trigger>
      <Trigger Property="IsEnabled" Value="False"><Setter Property="Background" Value="{DynamicResource B.Bg.Canvas}"/><Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Combo" TargetType="ComboBox">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.InputBorder}"/>
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.Control}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Outside}"/>
    <Setter Property="Padding" Value="10,0,32,0"/>
    <Setter Property="ItemContainerStyle" Value="{StaticResource Combo.Item}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ComboBox">
          <Grid>
            <ToggleButton Focusable="False" ClickMode="Press"
                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
              <ToggleButton.Template>
                <ControlTemplate TargetType="ToggleButton">
                  <Border x:Name="Bd" CornerRadius="4" BorderThickness="{Binding BorderThickness, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                          Background="{Binding Background, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                          BorderBrush="{Binding BorderBrush, RelativeSource={RelativeSource AncestorType=ComboBox}}">
                    <TextBlock Text="&#xE70D;" FontFamily="{DynamicResource Font.Icon}" FontSize="12" Foreground="{DynamicResource B.SubText}"
                               HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0"/>
                  </Border>
                </ControlTemplate>
              </ToggleButton.Template>
            </ToggleButton>
            <ContentPresenter IsHitTestVisible="False" Margin="{TemplateBinding Padding}" VerticalAlignment="Center" HorizontalAlignment="Left"
                              Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
            <Popup x:Name="PART_Popup" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="None"
                   IsOpen="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
              <Border Background="{DynamicResource B.Card}" BorderBrush="{DynamicResource B.Border}" BorderThickness="1" CornerRadius="8"
                      Padding="0,4" Margin="0,4,0,0" MaxHeight="{TemplateBinding MaxDropDownHeight}"
                      MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
                <ScrollViewer><ItemsPresenter/></ScrollViewer>
              </Border>
            </Popup>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsKeyboardFocusWithin" Value="True">
              <Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/><Setter Property="BorderThickness" Value="2"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter Property="Background" Value="{DynamicResource B.Bg.Canvas}"/><Setter Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/><Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/><Setter Property="Opacity" Value="1"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- 끝을 알 수 없는 진행 표시: 얇은 막대 -->
  <Style x:Key="Busy" TargetType="ProgressBar">
    <Setter Property="Height" Value="4"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Accent}"/>
    <Setter Property="Background" Value="{DynamicResource B.Bg.Subtle}"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="IsIndeterminate" Value="True"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ProgressBar"><Grid Background="{TemplateBinding Background}"><Border x:Name="PART_Track"/><Border x:Name="PART_Indicator" Width="32" HorizontalAlignment="Left" Background="{TemplateBinding Foreground}" CornerRadius="2"/></Grid></ControlTemplate></Setter.Value></Setter>
  </Style>

  <!-- 편집 칸: 카드 안을 채우는 테두리 없는 여러 줄 입력 (메모 본문 등) -->
  <Style x:Key="Editor" TargetType="TextBox" BasedOn="{StaticResource Input}">
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.Body}"/>
    <Setter Property="TextBlock.LineHeight" Value="{DynamicResource F.Memo.Body.LineHeight}"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Padding" Value="0"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
    <Setter Property="AcceptsReturn" Value="True"/>
    <Setter Property="AcceptsTab" Value="True"/>
    <Setter Property="VerticalContentAlignment" Value="Top"/>
    <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Style.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="BorderThickness" Value="0"/></Trigger></Style.Triggers>
  </Style>
  <!-- 제목 입력: 글자처럼 보이는 한 줄 입력 (포커스가 가면 아래 선이 강조색) -->
  <Style x:Key="Input.Title" TargetType="TextBox" BasedOn="{StaticResource Input}">
    <Setter Property="BorderThickness" Value="0,0,0,1"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Padding" Value="0,2"/>
    <Setter Property="MinHeight" Value="0"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.H1}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Memo.H1.Weight}"/>
    <Setter Property="TextBlock.LineHeight" Value="{DynamicResource F.Memo.H1.LineHeight}"/>
    <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="BorderBrush" Value="{DynamicResource B.Border.Control}"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/><Setter Property="BorderThickness" Value="0,0,0,2"/></Trigger></Style.Triggers>
  </Style>

  <Style x:Key="Row" TargetType="ListBoxItem">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/>
    <Setter Property="Background" Value="{DynamicResource B.Bg.Surface}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/>
    <Setter Property="BorderThickness" Value="0,0,0,1"/>
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.Control}"/>
    <Setter Property="Padding" Value="12,0"/>
    <Setter Property="Margin" Value="0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Inside}"/>
    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem">
      <Grid>
        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/></Border>
        <Border x:Name="SelectedBar" Width="3" Height="16" CornerRadius="1.5" Background="{DynamicResource B.Accent}" HorizontalAlignment="Left" VerticalAlignment="Center" Visibility="Collapsed"/>
      </Grid>
      <ControlTemplate.Triggers><Trigger Property="IsSelected" Value="True"><Setter TargetName="SelectedBar" Property="Visibility" Value="Visible"/></Trigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/></Trigger>
      <MultiTrigger><MultiTrigger.Conditions><Condition Property="IsMouseOver" Value="True"/><Condition Property="IsMouseCaptured" Value="True"/></MultiTrigger.Conditions><Setter Property="Background" Value="{DynamicResource B.Fill.Pressed.Surface}"/></MultiTrigger>
      <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource B.Bg.Selected}"/></Trigger>
      <Trigger Property="IsEnabled" Value="False"><Setter Property="Background" Value="{DynamicResource B.Bg.Canvas}"/><Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/><Setter Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="List" TargetType="ListBox">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="ItemContainerStyle" Value="{StaticResource Row}"/>
    <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
    <Setter Property="ScrollViewer.CanContentScroll" Value="True"/>
    <Setter Property="VirtualizingPanel.IsVirtualizing" Value="True"/>
    <Setter Property="VirtualizingPanel.VirtualizationMode" Value="Recycling"/>
    <Setter Property="ItemsPanel"><Setter.Value><ItemsPanelTemplate><VirtualizingStackPanel/></ItemsPanelTemplate></Setter.Value></Setter>
  </Style>

  <DataTemplate x:Key="Memo.Item">
    <StackPanel>
      <DockPanel>
        <TextBlock DockPanel.Dock="Right" Text="&#xE718;" Visibility="{Binding PinShown}" Style="{DynamicResource T.Icon}" FontSize="12" Foreground="{DynamicResource B.Text.Tertiary}" Margin="8,0,0,0" VerticalAlignment="Center" ToolTip="고정"/>
        <TextBlock Text="{Binding Title}" Style="{DynamicResource T.Body}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
      </DockPanel>
      <TextBlock Text="{Binding Sub}" Style="{DynamicResource T.CaptionMuted}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
    </StackPanel>
  </DataTemplate>
  <Style x:Key="Memo.List" TargetType="ListBox" BasedOn="{StaticResource List}">
    <Setter Property="ItemTemplate" Value="{StaticResource Memo.Item}"/>
    <Setter Property="ItemContainerStyle" Value="{DynamicResource Memo.Row}"/>

  </Style>

  <!-- 메모 칸(pane): 맨 위 탭 줄이 카드 가장자리에 붙도록 안쪽 여백 없는 카드 -->
  <Style x:Key="Memo.Pane" TargetType="Border" BasedOn="{StaticResource Card}">
    <Setter Property="Padding" Value="0"/>
  </Style>
  <Style x:Key="Memo.TabBar" TargetType="Border">
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/>
    <Setter Property="BorderThickness" Value="0,0,0,1"/>
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.MemoTabBar}"/>
    <Setter Property="Padding" Value="9,6,8,6"/>

  </Style>
  <!-- 메모 탭 하나. 선택 표시는 바탕 + 아래 가운데 막대(3 × 16). 막대 색은 BorderBrush로 받는다
       Memo.Tab: 선택 안 됨 · Memo.Tab.Current: 포커스가 있는 칸의 지금 탭 · Memo.Tab.Selected: 다른 칸의 지금 탭(덜 강조) -->
  <Style x:Key="Memo.Tab" TargetType="Button">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Secondary}"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.MemoTab}"/>
    <Setter Property="MinWidth" Value="120"/>
    <Setter Property="MaxWidth" Value="240"/>
    <Setter Property="Padding" Value="12,0,0,0"/>
    <Setter Property="Margin" Value="0,0,4,0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Inside}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Grid>
        <Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}"><ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="False"/></Border>
        <Border Height="2" Margin="8,0" Background="{TemplateBinding BorderBrush}" VerticalAlignment="Bottom"/>
      </Grid>
    </ControlTemplate></Setter.Value></Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/>
      </Trigger>
      <Trigger Property="IsPressed" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Pressed.Surface}"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False">
        <Setter Property="Background" Value="{DynamicResource B.Bg.Canvas}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/>
    <Setter Property="Opacity" Value="1"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Memo.Tab.Selected" TargetType="Button" BasedOn="{StaticResource Memo.Tab}">
    <Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/>
      </Trigger>
      <Trigger Property="IsPressed" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Pressed.Surface}"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False">
        <Setter Property="Background" Value="{DynamicResource B.Bg.Canvas}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/>
    <Setter Property="Opacity" Value="1"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Memo.Tab.Current" TargetType="Button" BasedOn="{StaticResource Memo.Tab}">
    <Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/>
      </Trigger>
      <Trigger Property="IsPressed" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Pressed.Surface}"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False">
        <Setter Property="Background" Value="{DynamicResource B.Bg.Canvas}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/>
    <Setter Property="Opacity" Value="1"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Memo.TabText" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="TextWrapping" Value="NoWrap"/>
    <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    <Setter Property="VerticalAlignment" Value="Center"/>
  </Style>
  <!-- 탭의 닫기(X). 탭 바탕(마우스 올림 · 선택)과 겹치지 않게 마우스 올림은 테두리 색 -->
  <Style x:Key="Memo.TabClose" TargetType="Button" BasedOn="{StaticResource Btn.Icon}">
    <Setter Property="Width" Value="24"/>
    <Setter Property="Height" Value="{DynamicResource F.Height.MemoTab}"/>
    <Setter Property="Margin" Value="0"/>
    <Setter Property="FontSize" Value="10"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Border Background="{TemplateBinding Background}" CornerRadius="4">
        <TextBlock Text="&#xE711;" FontFamily="{DynamicResource Font.Icon}" FontSize="10" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{TemplateBinding Foreground}"/>
      </Border>
    </ControlTemplate></Setter.Value></Setter>

  </Style>
  <Style x:Key="Memo.ListBody" TargetType="DockPanel"><Setter Property="Margin" Value="12,0,12,8"/></Style>
  <Style x:Key="Memo.SearchRow" TargetType="DockPanel"><Setter Property="Margin" Value="0,0,0,8"/></Style>
  <Style x:Key="Memo.Chips" TargetType="WrapPanel"><Setter Property="Margin" Value="0,0,0,4"/></Style>
  <Style x:Key="Memo.ViewRow" TargetType="DockPanel"><Setter Property="Margin" Value="0,0,0,4"/></Style>
  <Style x:Key="Memo.ViewPick" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="BorderThickness" Value="0"/><Setter Property="Background" Value="Transparent"/><Setter Property="Padding" Value="4,0"/>
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.Compact}"/><Setter Property="HorizontalAlignment" Value="Left"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Secondary}"/>
  </Style>
  <Style x:Key="Memo.Tag" TargetType="Button">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/><Setter Property="FontSize" Value="{DynamicResource F.Small}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Accent.Text}"/><Setter Property="Background" Value="{DynamicResource B.Bg.Selected}"/>
    <Setter Property="Height" Value="{DynamicResource F.Height.Chip}"/><Setter Property="Padding" Value="8,0"/><Setter Property="Margin" Value="0,0,4,0"/>
    <Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Outside}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Border Background="{TemplateBinding Background}" CornerRadius="{DynamicResource F.Radius.Control}" Padding="{TemplateBinding Padding}"><ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="False"/></Border>
    </ControlTemplate></Setter.Value></Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Canvas}"/></Trigger>
      <Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="{DynamicResource B.Fill.Pressed.Canvas}"/></Trigger>
    </Style.Triggers>
  </Style>
  <DataTemplate x:Key="Memo.TocItem">
    <TextBlock Text="{Binding Text}" Margin="{Binding Indent}" Style="{DynamicResource T.Body}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTip="{Binding Text}"/>
  </DataTemplate>
  <Style x:Key="Memo.TocRow" TargetType="ListBoxItem" BasedOn="{StaticResource Row}">
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.Checklist}"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="8,0"/>
  </Style>
  <Style x:Key="Memo.Toc" TargetType="ListBox" BasedOn="{StaticResource List}">
    <Setter Property="ItemTemplate" Value="{StaticResource Memo.TocItem}"/>
    <Setter Property="ItemContainerStyle" Value="{DynamicResource Memo.TocRow}"/>
    <Setter Property="Margin" Value="8,0,8,8"/>
  </Style>
  <!-- 두 칸 사이 경계: 폭 8(칸 사이 간격)을 끌어 폭을 바꾼다. 마우스를 올리거나 끌 때만 가운데 선이 보인다 -->
  <Style x:Key="Memo.Splitter" TargetType="GridSplitter">
    <Setter Property="Width" Value="8"/>
    <Setter Property="HorizontalAlignment" Value="Stretch"/>
    <Setter Property="VerticalAlignment" Value="Stretch"/>
    <Setter Property="ResizeDirection" Value="Columns"/>
    <Setter Property="ResizeBehavior" Value="PreviousAndNext"/>
    <Setter Property="Cursor" Value="SizeWE"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Outside}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="GridSplitter">
          <Grid Background="Transparent">
            <Border x:Name="Line" Width="2" CornerRadius="1" Margin="0,16" Background="Transparent"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="Line" Property="Background" Value="{DynamicResource B.InputBorder}"/>
            </Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True">
              <Setter TargetName="Line" Property="Background" Value="{DynamicResource B.Text}"/>
            </Trigger>
            <Trigger Property="IsDragging" Value="True">
              <Setter TargetName="Line" Property="Background" Value="{DynamicResource B.Accent}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <!-- 빠른 이동(Ctrl+O): 메모 화면 위 가운데에 겹쳐 뜨는 검색 상자 + 결과 목록. 외곽 면은 Overlay.Shadow를 뒤에 깐다 -->
  <Style x:Key="Memo.QuickHost" TargetType="Grid">
    <Setter Property="Width" Value="560"/>
    <Setter Property="HorizontalAlignment" Value="Center"/>
    <Setter Property="VerticalAlignment" Value="Top"/>
    <Setter Property="Margin" Value="0,24,0,0"/>
  </Style>
  <Style x:Key="Memo.QuickPanel" TargetType="Border" BasedOn="{StaticResource Card}">
    <Setter Property="CornerRadius" Value="{DynamicResource F.Radius.Overlay}"/>
    <Setter Property="Padding" Value="12"/>
  </Style>
  <DataTemplate x:Key="Memo.QuickItem">
    <StackPanel>
      <TextBlock Text="{Binding Title}" Style="{DynamicResource T.Strong}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="Sub" Text="{Binding Sub}" Style="{DynamicResource T.Sub}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
    </StackPanel>
    <DataTemplate.Triggers>
      <DataTrigger Binding="{Binding Sub}" Value="">
        <Setter TargetName="Sub" Property="Visibility" Value="Collapsed"/>
      </DataTrigger>
    </DataTemplate.Triggers>
  </DataTemplate>
  <Style x:Key="Memo.QuickList" TargetType="ListBox" BasedOn="{StaticResource List}">
    <Setter Property="ItemTemplate" Value="{StaticResource Memo.QuickItem}"/>
    <Setter Property="MaxHeight" Value="400"/>
    <Setter Property="Margin" Value="0,8,0,0"/>
  </Style>
  <!-- 카드 안 머리줄 56: 문서 · 활성 작업. 일정 · 근태는 전용 스타일에 같은 값을 쓴다 -->
  <Style x:Key="Card.Head" TargetType="DockPanel"><Setter Property="Height" Value="{DynamicResource F.Height.Header}"/><Setter Property="Margin" Value="16,0,16,0"/></Style>
  <Style x:Key="Card.Body" TargetType="Grid"><Setter Property="Margin" Value="16,0,16,0"/></Style>
  <Style x:Key="Card.Foot" TargetType="DockPanel"><Setter Property="Margin" Value="16,8,16,12"/></Style>
  <Style x:Key="Doc.TreeHead" TargetType="DockPanel"><Setter Property="Height" Value="{DynamicResource F.Height.Header}"/><Setter Property="Margin" Value="16,0,8,0"/></Style>
  <Style x:Key="Doc.TreeFoot" TargetType="Button" BasedOn="{StaticResource Btn.Link}"><Setter Property="HorizontalAlignment" Value="Left"/><Setter Property="Margin" Value="8,8,8,8"/></Style>
  <Style x:Key="Doc.Columns" TargetType="Border"><Setter Property="MinHeight" Value="{DynamicResource F.Height.Control}"/><Setter Property="BorderBrush" Value="{DynamicResource B.Border.Default}"/><Setter Property="BorderThickness" Value="0,0,0,1"/><Setter Property="Padding" Value="12,0"/></Style>
  <Style x:Key="Doc.Column" TargetType="TextBlock" BasedOn="{StaticResource T.Sub}"><Setter Property="Foreground" Value="{DynamicResource B.Text.Tertiary}"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Margin" Value="12,0,0,0"/></Style>
  <Style x:Key="Doc.Row" TargetType="ListBoxItem" BasedOn="{StaticResource Row}">
    <Setter Property="Tag" Value="{Binding}"/>
    <Setter Property="ToolTip" Value="{Binding Path}"/>
  </Style>
  <DataTemplate x:Key="Doc.Item">
    <DockPanel>
      <TextBlock DockPanel.Dock="Right" Text="{Binding SizeText}" Style="{DynamicResource T.Sub}" Width="80" TextAlignment="Right" Margin="12,0,0,0" VerticalAlignment="Center"/>
      <TextBlock DockPanel.Dock="Right" Text="{Binding ModifiedText}" Style="{DynamicResource T.Sub}" Width="130" Margin="12,0,0,0" VerticalAlignment="Center"/>
      <TextBlock DockPanel.Dock="Right" Text="{Binding Kind}" Style="{DynamicResource T.Sub}" Width="90" Margin="12,0,0,0" VerticalAlignment="Center"/>
      <TextBlock x:Name="DocIcon" DockPanel.Dock="Left" Text="{Binding IconText}" Style="{DynamicResource T.Icon}" Foreground="{DynamicResource B.SubText}" Width="20"/>
      <TextBlock x:Name="DocName" Text="{Binding Name}" Style="{DynamicResource T.Body}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis" Margin="8,0,0,0" VerticalAlignment="Center"/>
    </DockPanel>
    <DataTemplate.Triggers>
      <DataTrigger Binding="{Binding Missing}" Value="True">
        <Setter TargetName="DocIcon" Property="Foreground" Value="{DynamicResource B.Warn}"/>
        <Setter TargetName="DocName" Property="Foreground" Value="{DynamicResource B.SubText}"/>
      </DataTrigger>
    </DataTemplate.Triggers>
  </DataTemplate>
  <Style x:Key="Doc.List" TargetType="ListBox" BasedOn="{StaticResource List}">
    <Setter Property="ItemContainerStyle" Value="{StaticResource Doc.Row}"/>
    <Setter Property="ItemTemplate" Value="{StaticResource Doc.Item}"/>
  </Style>

  <!-- 트리 (문서 탭 폴더 등): 펼침 화살표 + 목록 행과 같은 둥근 바탕 -->
  <Style x:Key="TreeExpander" TargetType="ToggleButton">
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="Width" Value="20"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ToggleButton">
          <Border Background="Transparent">
            <TextBlock x:Name="Glyph" Text="&#xE76C;" FontFamily="{DynamicResource Font.Icon}" FontSize="10"
                       Foreground="{DynamicResource B.SubText}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Glyph" Property="Text" Value="&#xE70D;"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="TreeItem" TargetType="TreeViewItem">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Padding" Value="8,0"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Outside}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TreeViewItem">
          <StackPanel>
            <Grid>
              <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="{DynamicResource F.Radius.Control}" Padding="{TemplateBinding Padding}"
                      MinHeight="{DynamicResource F.Height.Compact}" BorderBrush="Transparent" BorderThickness="1">
                <DockPanel>
                  <ToggleButton x:Name="Expander" DockPanel.Dock="Left" Style="{StaticResource TreeExpander}" ClickMode="Press"
                                IsChecked="{Binding IsExpanded, RelativeSource={RelativeSource TemplatedParent}}"/>
                  <ContentPresenter ContentSource="Header" VerticalAlignment="Center" Margin="4,0,0,0" RecognizesAccessKey="False"/>
                </DockPanel>
              </Border>
              <Border x:Name="SelectedBar" Width="3" Height="16" CornerRadius="1.5" Background="{DynamicResource B.Accent}" HorizontalAlignment="Left" VerticalAlignment="Center" Visibility="Collapsed" IsHitTestVisible="False"/>
            </Grid>
            <ItemsPresenter x:Name="ItemsHost" Margin="16,0,0,0" Visibility="Collapsed"/>
          </StackPanel>
          <ControlTemplate.Triggers>
            <Trigger Property="IsExpanded" Value="True">
              <Setter TargetName="ItemsHost" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="HasItems" Value="False">
              <Setter TargetName="Expander" Property="Visibility" Value="Hidden"/>
            </Trigger>
            <Trigger SourceName="Bd" Property="IsMouseOver" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.Hover}"/>
            </Trigger>
            <Trigger Property="IsSelected" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.AccentSoft}"/>
              <Setter TargetName="SelectedBar" Property="Visibility" Value="Visible"/>
            </Trigger>
            <MultiTrigger>
              <MultiTrigger.Conditions>
                <Condition Property="IsSelected" Value="True"/>
                <Condition Property="IsKeyboardFocusWithin" Value="True"/>
              </MultiTrigger.Conditions>
              <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource B.Accent}"/>
            </MultiTrigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Tree" TargetType="TreeView">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="ItemContainerStyle" Value="{StaticResource TreeItem}"/>
    <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
  </Style>
  <Style x:Key="Doc.Tree" TargetType="TreeView" BasedOn="{StaticResource Tree}"><Setter Property="Margin" Value="8,0,8,0"/></Style>

  <!-- 체크 상자: 표의 선택 상자(Task.Check)와 같은 16 상자 + 오른쪽 글자. 글자를 눌러도 바뀐다 -->
  <Style x:Key="Check" TargetType="CheckBox">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/>
    <Setter Property="Background" Value="{DynamicResource B.Bg.Surface}"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Margin" Value="0,4"/>
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.Checklist}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Inside}"/>
    <Setter Property="ToolTipService.ShowOnDisabled" Value="True"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
      <Border x:Name="HitArea" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
        <DockPanel>
          <Border x:Name="Box" DockPanel.Dock="Left" Width="16" Height="16" CornerRadius="2" Background="{DynamicResource B.Bg.Surface}" BorderBrush="{DynamicResource B.Border.Control}" BorderThickness="1" VerticalAlignment="Center">
            <Grid><TextBlock x:Name="Mark" Text="&#xE73E;" FontFamily="{DynamicResource Font.Icon}" FontSize="12" Foreground="{DynamicResource B.OnAccent}" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/><Border x:Name="Dash" Width="8" Height="2" Background="{DynamicResource B.OnAccent}" Visibility="Collapsed"/></Grid>
          </Border>
          <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="False"/>
        </DockPanel>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="HitArea" Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter TargetName="HitArea" Property="Background" Value="{DynamicResource B.Fill.Pressed.Surface}"/></Trigger>
        <Trigger Property="IsChecked" Value="True"><Setter TargetName="Box" Property="Background" Value="{DynamicResource B.Accent}"/><Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource B.Accent}"/><Setter TargetName="Mark" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsChecked" Value="{x:Null}"><Setter TargetName="Box" Property="Background" Value="{DynamicResource B.Accent}"/><Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource B.Accent}"/><Setter TargetName="Dash" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Box" Property="Background" Value="{DynamicResource B.Bg.Canvas}"/><Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/><Setter TargetName="Mark" Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
    <Style.Triggers>      <Trigger Property="IsEnabled" Value="False">
        <Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/>
      </Trigger></Style.Triggers>
  </Style>

  <!-- 스크롤 막대: 화살표 없이 둥근 손잡이만 (막대 폭 12 · 손잡이 8). 키 없는 스타일이라 창 안의 모든 스크롤에 쓰인다 -->
  <Style x:Key="Scroll.Thumb" TargetType="Thumb">
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Thumb">
          <Border x:Name="Bd" Background="{DynamicResource B.InputBorder}" CornerRadius="4"/>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.SubText}"/>
            </Trigger>
            <Trigger Property="IsDragging" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.Text}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Scroll.Page" TargetType="RepeatButton">
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="IsTabStop" Value="False"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="ScrollBar">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Width" Value="12"/>
    <Setter Property="MinWidth" Value="12"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Border Background="{TemplateBinding Background}">
            <Track x:Name="PART_Track" IsDirectionReversed="True" Margin="2">
              <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource Scroll.Page}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
              <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource Scroll.Page}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
              <Track.Thumb><Thumb Style="{StaticResource Scroll.Thumb}"/></Track.Thumb>
            </Track>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="Orientation" Value="Horizontal">
        <Setter Property="Width" Value="Auto"/>
        <Setter Property="MinWidth" Value="0"/>
        <Setter Property="Height" Value="12"/>
        <Setter Property="MinHeight" Value="12"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Border Background="{TemplateBinding Background}">
                <Track x:Name="PART_Track" Margin="2">
                  <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource Scroll.Page}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
                  <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource Scroll.Page}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
                  <Track.Thumb><Thumb Style="{StaticResource Scroll.Thumb}"/></Track.Thumb>
                </Track>
              </Border>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Trigger>
    </Style.Triggers>
  </Style>
  <!-- 기본 모양과 같고, 가로 · 세로 막대가 만나는 모서리만 회색 칸 대신 비워 둔다 -->
  <Style TargetType="ScrollViewer">
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ScrollViewer">
          <Grid Background="{TemplateBinding Background}">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <ScrollContentPresenter x:Name="PART_ScrollContentPresenter" Margin="{TemplateBinding Padding}"
                                    CanContentScroll="{TemplateBinding CanContentScroll}" CanHorizontallyScroll="False" CanVerticallyScroll="False"
                                    Content="{TemplateBinding Content}" ContentTemplate="{TemplateBinding ContentTemplate}"/>
            <ScrollBar x:Name="PART_VerticalScrollBar" Grid.Column="1" AutomationProperties.AutomationId="VerticalScrollBar" Cursor="Arrow"
                       Minimum="0" Maximum="{TemplateBinding ScrollableHeight}" ViewportSize="{TemplateBinding ViewportHeight}"
                       Value="{Binding VerticalOffset, Mode=OneWay, RelativeSource={RelativeSource TemplatedParent}}"
                       Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}"/>
            <ScrollBar x:Name="PART_HorizontalScrollBar" Grid.Row="1" Orientation="Horizontal" AutomationProperties.AutomationId="HorizontalScrollBar" Cursor="Arrow"
                       Minimum="0" Maximum="{TemplateBinding ScrollableWidth}" ViewportSize="{TemplateBinding ViewportWidth}"
                       Value="{Binding HorizontalOffset, Mode=OneWay, RelativeSource={RelativeSource TemplatedParent}}"
                       Visibility="{TemplateBinding ComputedHorizontalScrollBarVisibility}"/>
          </Grid>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- 값 고르기 막대(Slider, 가로): 높이 4 막대 + 지름 20 손잡이. 고른 쪽은 강조색 -->
  <Style x:Key="Range.Fill" TargetType="RepeatButton">
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="IsTabStop" Value="False"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RepeatButton">
          <Grid Background="Transparent"><Border Height="4" CornerRadius="2" Background="{TemplateBinding Background}" VerticalAlignment="Center"/></Grid>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Range.Thumb" TargetType="Thumb">
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.InputBorder}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Thumb">
          <Grid Width="20" Height="20">
            <Ellipse x:Name="Ring" Fill="{DynamicResource B.Card}" Stroke="{TemplateBinding BorderBrush}" StrokeThickness="1"/>
            <Ellipse x:Name="Dot" Width="12" Height="12" Fill="{DynamicResource B.Accent}"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Dot" Property="Width" Value="14"/><Setter TargetName="Dot" Property="Height" Value="14"/></Trigger>
            <Trigger Property="IsDragging" Value="True"><Setter TargetName="Dot" Property="Width" Value="10"/><Setter TargetName="Dot" Property="Height" Value="10"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Range" TargetType="Slider">
    <Setter Property="MinHeight" Value="32"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Outside}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Slider">
          <Grid Background="Transparent">
            <Track x:Name="PART_Track">
              <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource Range.Fill}" Background="{DynamicResource B.Accent}" Command="Slider.DecreaseLarge"/></Track.DecreaseRepeatButton>
              <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource Range.Fill}" Background="{DynamicResource B.InputBorder}" Command="Slider.IncreaseLarge"/></Track.IncreaseRepeatButton>
              <Track.Thumb><Thumb x:Name="Thumb" Style="{StaticResource Range.Thumb}"/></Track.Thumb>
            </Track>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Thumb" Property="BorderBrush" Value="{DynamicResource B.Text}"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="1"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- 옛 Overlay.Shadow 이름은 호환용이다. 2판은 효과 없이 면·선만 둔다. -->
  <Style x:Key="Overlay.Shadow" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource B.Bg.Raised}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Default}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CornerRadius" Value="{DynamicResource F.Radius.Overlay}"/>

  </Style>

  <!-- 마크다운 보기 (Markdown.psm1). 문서 요소(Paragraph · Section · Run …)의 모양 -->
  <!-- RichTextBox는 배치할 때 문서 좌우에 5씩 여백을 넣는다(PagePadding 5,0). 안쪽 여백 -5로 없애서 옆 글과 줄을 맞춘다 -->
  <Style x:Key="Md.View" TargetType="RichTextBox">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Padding" Value="-5,0,-5,0"/>
    <Setter Property="AcceptsTab" Value="False"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Outside}"/>
    <Setter Property="HorizontalScrollBarVisibility" Value="Disabled"/>
  </Style>
  <Style x:Key="Md.Doc" TargetType="FlowDocument">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.Memo.Body.LineHeight}"/>
    <Setter Property="PagePadding" Value="0"/>
    <Setter Property="TextAlignment" Value="Left"/>
  </Style>
  <Style x:Key="Md.P" TargetType="Paragraph">
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>
  <Style x:Key="Md.PTight" TargetType="Paragraph">
    <Setter Property="Margin" Value="0"/>
  </Style>
  <Style x:Key="Md.H1" TargetType="Paragraph">
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.H1}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Memo.H1.Weight}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.Memo.H1.LineHeight}"/>
    <Setter Property="Margin" Value="0,24,0,12"/>
  </Style>
  <Style x:Key="Md.H2" TargetType="Paragraph" BasedOn="{StaticResource Md.H1}">
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.H2}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Memo.H2.Weight}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.Memo.H2.LineHeight}"/>
    <Setter Property="Margin" Value="0,24,0,8"/>
  </Style>
  <Style x:Key="Md.H3" TargetType="Paragraph" BasedOn="{StaticResource Md.H2}">
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.H3}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Memo.H3.Weight}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.Memo.H3.LineHeight}"/>
    <Setter Property="Margin" Value="0,16,0,8"/>
  </Style>
  <Style x:Key="Md.H4" TargetType="Paragraph" BasedOn="{StaticResource Md.H2}">
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.H4}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Memo.H4.Weight}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.Memo.H4.LineHeight}"/>
    <Setter Property="Margin" Value="0,16,0,4"/>
  </Style>
  <Style x:Key="Md.H5" TargetType="Paragraph" BasedOn="{StaticResource Md.H4}">
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.H5}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Memo.H5.Weight}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.Memo.H5.LineHeight}"/>
  </Style>
  <Style x:Key="Md.H6" TargetType="Paragraph" BasedOn="{StaticResource Md.H5}">
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.H6}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Memo.H6.Weight}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.Memo.H6.LineHeight}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
  </Style>
  <Style x:Key="Md.List" TargetType="List">
    <Setter Property="Margin" Value="0,0,0,12"/>
    <Setter Property="Padding" Value="24,0,0,0"/>
  </Style>
  <Style x:Key="Md.ListNested" TargetType="List" BasedOn="{StaticResource Md.List}">
    <Setter Property="Margin" Value="0,4,0,0"/>
  </Style>
  <Style x:Key="Md.ListItem" TargetType="ListItem">
    <Setter Property="Margin" Value="0,0,0,4"/>
  </Style>
  <Style x:Key="Md.Quote" TargetType="Section">
    <Setter Property="BorderBrush" Value="{DynamicResource B.Md.QuoteBar}"/>
    <Setter Property="BorderThickness" Value="3,0,0,0"/>
    <Setter Property="Padding" Value="16,4,0,4"/>
    <Setter Property="Margin" Value="0,0,0,12"/>
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
  </Style>
  <Style x:Key="Md.Callout" TargetType="Section">
    <Setter Property="BorderThickness" Value="3,0,0,0"/>
    <Setter Property="Padding" Value="16,12,16,12"/>
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>
  <Style x:Key="Md.CalloutTitle" TargetType="Paragraph">
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Margin" Value="0,0,0,8"/>
  </Style>
  <Style x:Key="Md.FoldLink" TargetType="Hyperlink">
    <Setter Property="TextDecorations" Value="{x:Null}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="TextDecorations" Value="Underline"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Md.CodeBlock" TargetType="Section">
    <Setter Property="Background" Value="{DynamicResource B.Code.Bg}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="12,0,8,12"/>
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>
  <Style x:Key="Md.CodeHead" TargetType="BlockUIContainer">
    <Setter Property="Margin" Value="0"/>
  </Style>
  <Style x:Key="Md.CodeText" TargetType="Paragraph">
    <Setter Property="FontFamily" Value="{DynamicResource Font.Mono}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.Code}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.Memo.Code.LineHeight}"/>
    <Setter Property="Margin" Value="0"/>
  </Style>
  <Style x:Key="Md.CodeNote" TargetType="Paragraph">
    <Setter Property="FontSize" Value="{DynamicResource F.Small}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Warn}"/>
    <Setter Property="Margin" Value="0,0,0,8"/>
  </Style>
  <Style x:Key="Md.InlineCode" TargetType="Run">
    <Setter Property="FontFamily" Value="{DynamicResource Font.Mono}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Code}"/>
    <Setter Property="Background" Value="{DynamicResource B.Code.Bg}"/>
  </Style>
  <Style x:Key="Md.Math" TargetType="Paragraph">
    <Setter Property="FontFamily" Value="{DynamicResource Font.Mono}"/>
    <Setter Property="Background" Value="{DynamicResource B.Code.Bg}"/>
    <Setter Property="Padding" Value="12,8"/>
    <Setter Property="Margin" Value="0,0,0,12"/>
    <Setter Property="TextAlignment" Value="Center"/>
  </Style>
  <Style x:Key="Md.Mark" TargetType="Span">
    <Setter Property="Background" Value="{DynamicResource B.Md.Mark}"/>
  </Style>
  <Style x:Key="Md.Sup" TargetType="Span">
    <Setter Property="BaselineAlignment" Value="Superscript"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Small}"/>
  </Style>
  <Style x:Key="Md.Sub" TargetType="Span">
    <Setter Property="BaselineAlignment" Value="Subscript"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Small}"/>
  </Style>
  <Style x:Key="Md.Tag" TargetType="Span">
    <Setter Property="Background" Value="{DynamicResource B.Chip}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.ChipText}"/>
  </Style>
  <Style x:Key="Md.Link" TargetType="Hyperlink">
    <Setter Property="Foreground" Value="{DynamicResource B.AccentStrong}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Foreground" Value="{DynamicResource B.AccentHover}"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Md.TagLink" TargetType="Hyperlink" BasedOn="{StaticResource Md.Link}">
    <Setter Property="Background" Value="{DynamicResource B.AccentSoft}"/>
    <Setter Property="TextDecorations" Value="{x:Null}"/>
  </Style>
  <Style x:Key="Md.FnRef" TargetType="Hyperlink" BasedOn="{StaticResource Md.Link}">
    <Setter Property="BaselineAlignment" Value="Superscript"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Small}"/>
    <Setter Property="TextDecorations" Value="{x:Null}"/>
  </Style>
  <Style x:Key="Md.TaskLink" TargetType="Hyperlink">
    <Setter Property="TextDecorations" Value="{x:Null}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Hover}"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Md.Hr" TargetType="BlockUIContainer">
    <Setter Property="Margin" Value="0,8,0,20"/>
  </Style>
  <Style x:Key="Md.Figure" TargetType="BlockUIContainer">
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>
  <Style x:Key="Md.FigureTight" TargetType="BlockUIContainer">
    <Setter Property="Margin" Value="0"/>
  </Style>
  <Style x:Key="Md.FigureBox" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CornerRadius" Value="8"/>
    <Setter Property="Padding" Value="12,0,8,16"/>
  </Style>
  <Style x:Key="Md.Table" TargetType="Table">
    <Setter Property="CellSpacing" Value="0"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>
  <Style x:Key="Md.Td" TargetType="TableCell">
    <Setter Property="Padding" Value="12,6"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="0,0,0,1"/>
  </Style>
  <Style x:Key="Md.Th" TargetType="TableCell" BasedOn="{StaticResource Md.Td}">
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Background" Value="{DynamicResource B.Code.Bg}"/>
  </Style>
  <Style x:Key="Md.Props" TargetType="Table" BasedOn="{StaticResource Md.Table}">
    <Setter Property="Background" Value="{DynamicResource B.Code.Bg}"/>
    <Setter Property="Margin" Value="0,0,0,16"/>
  </Style>
  <Style x:Key="Md.PropKey" TargetType="TableCell">
    <Setter Property="Padding" Value="12,4"/>
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
  </Style>
  <Style x:Key="Md.PropValue" TargetType="TableCell">
    <Setter Property="Padding" Value="12,4"/>
  </Style>
  <Style x:Key="Md.Footnotes" TargetType="Section">
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="0,1,0,0"/>
    <Setter Property="Padding" Value="0,12,0,0"/>
    <Setter Property="Margin" Value="0,12,0,0"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Small}"/>
    <Setter Property="LineHeight" Value="Auto"/>
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
  </Style>
  <!-- 그리면 보이지 않는 줄(링크 정의 · 주석)을 편집 화면에서 원문 그대로 흐리게 -->
  <Style x:Key="Md.Raw" TargetType="Paragraph">
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>

  <!-- 메모 실시간 편집: 고치는 블록 자리에 들어가는 원문 입력칸(섬). 그린 글과 같은 글꼴 · 줄 높이 -->
  <Style x:Key="Memo.Island" TargetType="TextBox">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Padding" Value="0"/>
    <Setter Property="Margin" Value="0"/>
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="CaretBrush" Value="{DynamicResource B.Text}"/>
    <Setter Property="TextBlock.LineHeight" Value="{DynamicResource F.Memo.Body.LineHeight}"/>
    <Setter Property="TextBlock.LineStackingStrategy" Value="BlockLineHeight"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
    <Setter Property="AcceptsReturn" Value="True"/>
    <Setter Property="AcceptsTab" Value="True"/>
    <Setter Property="VerticalScrollBarVisibility" Value="Disabled"/>
    <Setter Property="HorizontalScrollBarVisibility" Value="Disabled"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Outside}"/>
    <Setter Property="HorizontalAlignment" Value="Stretch"/>
  </Style>
  <Style x:Key="Memo.IslandH1" TargetType="TextBox" BasedOn="{StaticResource Memo.Island}">
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.H1}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Memo.H1.Weight}"/>
    <Setter Property="TextBlock.LineHeight" Value="{DynamicResource F.Memo.H1.LineHeight}"/>
  </Style>
  <Style x:Key="Memo.IslandH2" TargetType="TextBox" BasedOn="{StaticResource Memo.IslandH1}">
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.H2}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Memo.H2.Weight}"/>
    <Setter Property="TextBlock.LineHeight" Value="{DynamicResource F.Memo.H2.LineHeight}"/>
  </Style>
  <Style x:Key="Memo.IslandH3" TargetType="TextBox" BasedOn="{StaticResource Memo.IslandH2}">
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.H3}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Memo.H3.Weight}"/>
    <Setter Property="TextBlock.LineHeight" Value="{DynamicResource F.Memo.H3.LineHeight}"/>
  </Style>
  <Style x:Key="Memo.IslandH4" TargetType="TextBox" BasedOn="{StaticResource Memo.IslandH2}">
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.H4}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Memo.H4.Weight}"/>
    <Setter Property="TextBlock.LineHeight" Value="{DynamicResource F.Memo.H4.LineHeight}"/>
  </Style>
  <Style x:Key="Memo.IslandH5" TargetType="TextBox" BasedOn="{StaticResource Memo.IslandH4}">
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.H5}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Memo.H5.Weight}"/>
    <Setter Property="TextBlock.LineHeight" Value="{DynamicResource F.Memo.H5.LineHeight}"/>
  </Style>
  <Style x:Key="Memo.IslandH6" TargetType="TextBox" BasedOn="{StaticResource Memo.IslandH5}">
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.H6}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Memo.H6.Weight}"/>
    <Setter Property="TextBlock.LineHeight" Value="{DynamicResource F.Memo.H6.LineHeight}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
  </Style>
  <Style x:Key="Memo.IslandCode" TargetType="TextBox" BasedOn="{StaticResource Memo.Island}">
    <Setter Property="FontFamily" Value="{DynamicResource Font.Mono}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.Code}"/>
    <Setter Property="TextBlock.LineHeight" Value="{DynamicResource F.Memo.Code.LineHeight}"/>
    <Setter Property="Background" Value="{DynamicResource B.Code.Bg}"/>
    <Setter Property="Padding" Value="12,8"/>
  </Style>
  <!-- 섬을 담는 블록: 그린 문단과 같은 아래 여백 -->
  <Style x:Key="Memo.IslandBox" TargetType="BlockUIContainer">
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>
  <!-- [[ 자동 완성 팝업: 떠 있는 패널(모서리 8 · 테두리). 항목은 포커스를 받지 않는다(입력칸에 커서를 둔 채 고름) -->
  <Style x:Key="Memo.Suggest" TargetType="Border">
    <Setter Property="CornerRadius" Value="{DynamicResource F.Radius.Overlay}"/>
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="4"/>
    <Setter Property="MinWidth" Value="240"/>
    <Setter Property="MaxWidth" Value="400"/>
  </Style>
  <Style x:Key="Memo.SuggestRow" TargetType="ListBoxItem" BasedOn="{StaticResource Row}">
    <Setter Property="Padding" Value="8,6"/>
    <Setter Property="Margin" Value="0"/>
    <Setter Property="Focusable" Value="False"/>
  </Style>
  <DataTemplate x:Key="Memo.SuggestItem">
    <TextBlock Text="{Binding}" Style="{DynamicResource T.Body}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
  </DataTemplate>
  <Style x:Key="Memo.SuggestList" TargetType="ListBox" BasedOn="{StaticResource List}">
    <Setter Property="ItemContainerStyle" Value="{StaticResource Memo.SuggestRow}"/>
    <Setter Property="ItemTemplate" Value="{StaticResource Memo.SuggestItem}"/>
    <Setter Property="MaxHeight" Value="240"/>
  </Style>
  <!-- 편집기 위 찾기 · 바꾸기 막대 -->
  <Style x:Key="Memo.FindBar" TargetType="Border">
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="0,0,0,1"/>
    <Setter Property="Padding" Value="0,0,0,8"/>
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>

  <!-- 활성 작업 표. 고르기 열 60: 체크 상자가 왼쪽 32, 이름이 72에 온다. 묶음 머리도 같은 자리에 맞춘다 (값 문서 8절) -->
  <Style x:Key="Task.Check" TargetType="CheckBox">
    <Setter Property="VerticalAlignment" Value="Center"/>
    <Setter Property="HorizontalAlignment" Value="Stretch"/>
    <Setter Property="Padding" Value="12,8"/>
    <Setter Property="MinHeight" Value="32"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
      <Border x:Name="HitArea" Padding="{TemplateBinding Padding}" Background="Transparent">
        <Border x:Name="Box" Width="16" Height="16" HorizontalAlignment="Left" VerticalAlignment="Center"
          CornerRadius="2" Background="{DynamicResource B.Card}" BorderBrush="{DynamicResource B.InputBorder}" BorderThickness="1">
          <Grid>
            <Path x:Name="Mark" Data="M 2,7 L 6,11 L 12,3" Stroke="{DynamicResource B.OnAccent}" StrokeThickness="2" Visibility="Collapsed"/>
            <Border x:Name="Dash" Width="8" Height="2" Background="{DynamicResource B.OnAccent}" Visibility="Collapsed"/>
          </Grid>
        </Border>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsChecked" Value="True"><Setter TargetName="Box" Property="Background" Value="{DynamicResource B.Accent}"/><Setter TargetName="Mark" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsChecked" Value="{x:Null}"><Setter TargetName="Box" Property="Background" Value="{DynamicResource B.Accent}"/><Setter TargetName="Dash" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="HitArea" Property="Background" Value="{DynamicResource B.Hover}"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter TargetName="HitArea" Property="Background" Value="{DynamicResource B.AccentSoft}"/></Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource B.Text}"/><Setter TargetName="Box" Property="BorderThickness" Value="2"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="1"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Task.GroupCheck" TargetType="CheckBox" BasedOn="{StaticResource Task.Check}"><Setter Property="Padding" Value="4,8,12,8"/></Style>
  <Style x:Key="Task.GroupToggle" TargetType="ToggleButton">
    <Setter Property="Width" Value="{DynamicResource F.Height.Compact}"/><Setter Property="Height" Value="{DynamicResource F.Height.Compact}"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Outside}"/><Setter Property="AutomationProperties.Name" Value="묶음 펼치기"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToggleButton">
      <Border x:Name="Bd" Background="Transparent" CornerRadius="{DynamicResource F.Radius.Control}">
        <TextBlock x:Name="Glyph" Text="&#xE76C;" FontFamily="{DynamicResource Font.Icon}" FontSize="10" Foreground="{DynamicResource B.Text.Secondary}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsChecked" Value="True"><Setter TargetName="Glyph" Property="Text" Value="&#xE70D;"/></Trigger>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.Fill.Pressed.Surface}"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <!-- 묶음 머리: 평평한 한 줄. 펼침 단추 · 체크 상자 · 이름 · 개수 -->
  <Style x:Key="Task.Group" TargetType="Expander">
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Expander">
      <DockPanel>
        <Border DockPanel.Dock="Top" MinHeight="{DynamicResource F.Height.Control}" BorderBrush="{DynamicResource B.Border.Muted}" BorderThickness="0,0,0,1">
          <DockPanel>
            <ToggleButton DockPanel.Dock="Left" Style="{StaticResource Task.GroupToggle}" VerticalAlignment="Center" IsChecked="{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
            <ContentPresenter ContentSource="Header" VerticalAlignment="Center" RecognizesAccessKey="False"/>
          </DockPanel>
        </Border>
        <ContentPresenter x:Name="Body" Visibility="Collapsed"/>
      </DockPanel>
      <ControlTemplate.Triggers><Trigger Property="IsExpanded" Value="True"><Setter TargetName="Body" Property="Visibility" Value="Visible"/></Trigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Task.Row" TargetType="DataGridRow">
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="DataGridRow">
      <Border Background="{TemplateBinding Background}"><Grid>
        <DataGridCellsPresenter/>
        <Border x:Name="SelectionMark" Width="3" Height="16" CornerRadius="1.5" HorizontalAlignment="Left" VerticalAlignment="Center" Background="{DynamicResource B.Accent}" Visibility="Collapsed" IsHitTestVisible="False"/>
      </Grid></Border>
      <ControlTemplate.Triggers><DataTrigger Binding="{Binding Selected}" Value="True"><Setter TargetName="SelectionMark" Property="Visibility" Value="Visible"/></DataTrigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
    <Setter Property="MinHeight" Value="32"/>
    <Setter Property="Background" Value="{DynamicResource B.Bg.Surface}"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/></Trigger>
      <DataTrigger Binding="{Binding Selected}" Value="True"><Setter Property="Background" Value="{DynamicResource B.Bg.Selected}"/></DataTrigger>
    </Style.Triggers>
  </Style>
  <!-- 표 칸: 바탕은 행이 칠한다. 활성 작업 · 근태가 같이 쓴다 -->
  <Style x:Key="Task.Cell" TargetType="DataGridCell">
    <Setter Property="Padding" Value="12,0"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="DataGridCell"><Border Padding="{TemplateBinding Padding}" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"><ContentPresenter VerticalAlignment="Center"/></Border></ControlTemplate></Setter.Value></Setter>
    <Style.Triggers><Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter Property="BorderThickness" Value="2"/><Setter Property="BorderBrush" Value="{DynamicResource B.Text.Primary}"/></Trigger></Style.Triggers>
  </Style>
  <Style x:Key="Task.CheckCell" TargetType="DataGridCell" BasedOn="{StaticResource Task.Cell}"><Setter Property="Padding" Value="20,0,0,0"/></Style>
  <!-- 표 머리: 바탕 없이 작은 글자 + 아래 선. 활성 작업 · 근태가 같이 쓴다 -->
  <Style x:Key="Task.Header" TargetType="DataGridColumnHeader">
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.Control}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Caption}"/>
    <Setter Property="FontWeight" Value="{DynamicResource F.Caption.Weight}"/>
    <Setter Property="Padding" Value="12,0"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Tertiary}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Default}"/>
    <Setter Property="BorderThickness" Value="0,0,0,1"/>
  </Style>
  <Style x:Key="Task.HeaderRight" TargetType="DataGridColumnHeader" BasedOn="{StaticResource Task.Header}"><Setter Property="HorizontalContentAlignment" Value="Right"/></Style>
  <Style x:Key="Task.Text" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="TextWrapping" Value="NoWrap"/>
    <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    <Setter Property="VerticalAlignment" Value="Center"/>
    <Setter Property="ToolTip" Value="{Binding RelativeSource={RelativeSource Self}, Path=Text}"/>
    <Style.Triggers><Trigger Property="Text" Value=""><Setter Property="ToolTip" Value="{x:Null}"/></Trigger></Style.Triggers>
  </Style>
  <Style x:Key="Task.Title" TargetType="TextBlock" BasedOn="{StaticResource T.Title}"><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Margin" Value="8,0,16,0"/></Style>
  <Style x:Key="Task.Filter" TargetType="Button" BasedOn="{StaticResource Btn}"><Setter Property="Margin" Value="8,0,0,0"/></Style>
  <!-- 설정 행: 라벨↔값 12, 행 사이 12 (값 문서 8절 설정·도움말) -->
  <Style x:Key="Setting.Row" TargetType="Grid"><Setter Property="Margin" Value="0,6"/><Setter Property="MinHeight" Value="{DynamicResource F.Height.Control}"/></Style>
  <Style x:Key="Setting.Label" TargetType="TextBlock" BasedOn="{StaticResource T.Body}"><Setter Property="Foreground" Value="{DynamicResource B.Text.Secondary}"/><Setter Property="Margin" Value="0,0,12,0"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Setting.Time" TargetType="TextBox" BasedOn="{StaticResource Input}"><Setter Property="Width" Value="120"/><Setter Property="HorizontalAlignment" Value="Left"/><Setter Property="FontFamily" Value="{DynamicResource Font.Mono}"/></Style>
  <Style x:Key="Btn.Compact" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.Compact}"/>

  </Style>
  <Style x:Key="Btn.Icon32" TargetType="Button" BasedOn="{StaticResource Btn.Icon}">
    <Setter Property="Width" Value="{DynamicResource F.Height.Control}"/>
    <Setter Property="Height" Value="{DynamicResource F.Height.Control}"/>

  </Style>
  <Style x:Key="Btn.Icon.Canvas" TargetType="Button" BasedOn="{StaticResource Btn.Icon}">

    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Canvas}"/>
      </Trigger>
      <Trigger Property="IsPressed" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Pressed.Canvas}"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False">
        <Setter Property="Background" Value="{DynamicResource B.Bg.Canvas}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/>
    <Setter Property="Opacity" Value="1"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Btn.Icon.Subtle" TargetType="Button" BasedOn="{StaticResource Btn.Icon}">

    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Subtle}"/>
      </Trigger>
      <Trigger Property="IsPressed" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Fill.Pressed.Subtle}"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False">
        <Setter Property="Background" Value="{DynamicResource B.Bg.Canvas}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/>
    <Setter Property="Opacity" Value="1"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Row.TwoLine" TargetType="ListBoxItem" BasedOn="{StaticResource Row}">
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.Row2}"/>

  </Style>
  <Style x:Key="Memo.Row" TargetType="ListBoxItem" BasedOn="{StaticResource Row}">
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.MemoRow}"/>

  </Style>
  <Style x:Key="T.CaptionMuted" TargetType="TextBlock" BasedOn="{StaticResource T.Sub}">
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Tertiary}"/>

  </Style>
  <Style x:Key="Tabs" TargetType="TabControl">
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TabControl">
      <DockPanel KeyboardNavigation.TabNavigation="Local">
        <TabPanel DockPanel.Dock="Top" IsItemsHost="True" Margin="8,0,8,0" KeyboardNavigation.TabIndex="1"/>
        <Border Background="{DynamicResource B.Bg.Surface}" CornerRadius="{DynamicResource F.Radius.Card}">
          <ContentPresenter x:Name="PART_SelectedContentHost" ContentSource="SelectedContent" Margin="0,8,0,8"/>
        </Border>
      </DockPanel>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Tab" TargetType="TabItem">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Secondary}"/>
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.Tab}"/>
    <Setter Property="Background" Value="{DynamicResource B.Bg.Canvas}"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Padding" Value="12,0"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Inside}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TabItem">
      <Grid><Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"><ContentPresenter ContentSource="Header" VerticalAlignment="Center"/></Border><Border Height="2" VerticalAlignment="Top" Background="{TemplateBinding BorderBrush}"/></Grid>
    </ControlTemplate></Setter.Value></Setter>
    <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource B.Bg.Surface}"/><Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/><Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/><Setter Property="Background" Value="{DynamicResource B.Bg.Canvas}"/></Trigger></Style.Triggers>
  </Style>
  <Style x:Key="Checklist.Row" TargetType="CheckBox" BasedOn="{StaticResource Check}">
    <Setter Property="Margin" Value="0"/>
    <Style.Triggers><Trigger Property="IsChecked" Value="True"><Setter Property="Foreground" Value="{DynamicResource B.Text.Tertiary}"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/></Trigger></Style.Triggers>
  </Style>
  <Style x:Key="Checklist.Row.Memo" TargetType="CheckBox" BasedOn="{StaticResource Checklist.Row}">
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.Body}"/>

  </Style>
  <Style x:Key="Chip" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource B.Bg.Selected}"/>
    <Setter Property="CornerRadius" Value="{DynamicResource F.Radius.Control}"/>
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.Chip}"/>
    <Setter Property="Padding" Value="8,0"/>

  </Style>
  <Style x:Key="Chip.Filter" TargetType="Border">
    <Setter Property="MinHeight" Value="{DynamicResource F.Height.FilterChip}"/>
    <Setter Property="Background" Value="{DynamicResource B.Bg.Subtle}"/>
    <Setter Property="CornerRadius" Value="{DynamicResource F.Radius.Control}"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/></Trigger>
      <MultiTrigger><MultiTrigger.Conditions><Condition Property="IsMouseOver" Value="True"/><Condition Property="IsMouseCaptureWithin" Value="True"/></MultiTrigger.Conditions><Setter Property="Background" Value="{DynamicResource B.Fill.Pressed.Surface}"/></MultiTrigger>
      <Trigger Property="IsEnabled" Value="False"><Setter Property="Background" Value="{DynamicResource B.Bg.Canvas}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Chip.Remove" TargetType="Button" BasedOn="{StaticResource Btn.Icon}">
    <Setter Property="Width" Value="20"/>
    <Setter Property="Height" Value="{DynamicResource F.Height.FilterChip}"/>
    <Setter Property="FontFamily" Value="{DynamicResource Font.Icon}"/>
    <Setter Property="FontSize" Value="10"/>
    <Setter Property="Content" Value="&#xE711;"/>

  </Style>
  <!-- 홈 2판 7·8절 전용 부품. 기능 모듈은 이 모양과 치수만 쓴다. -->
  <Style x:Key="Home.Head" TargetType="StackPanel"><Setter Property="Margin" Value="8,20,8,16"/></Style>
  <Style x:Key="Home.Card" TargetType="Border" BasedOn="{StaticResource Card}"/>
  <Style x:Key="Home.NextPill" TargetType="Border"><Setter Property="Height" Value="22"/><Setter Property="CornerRadius" Value="{DynamicResource F.Radius.Control}"/><Setter Property="Padding" Value="8,0"/><Setter Property="Background" Value="{DynamicResource B.Accent}"/></Style>
  <Style x:Key="Home.NextPillText" TargetType="TextBlock" BasedOn="{StaticResource T.Sub}"><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="{DynamicResource B.OnAccent}"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Home.Tile" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Height" Value="48"/><Setter Property="Padding" Value="8,0"/><Setter Property="Margin" Value="-8,0"/>
    <Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/>
    <Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Inside}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Border Background="{TemplateBinding Background}" CornerRadius="{DynamicResource F.Radius.Control}" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Center"/></Border>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Home.CalendarDay" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Width" Value="40"/><Setter Property="Height" Value="32"/><Setter Property="MinHeight" Value="32"/>
    <Setter Property="Padding" Value="0"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Background" Value="Transparent"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Inside}"/>
    <Style.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/><Setter Property="BorderThickness" Value="1"/></Trigger></Style.Triggers>
  </Style>
  <Style x:Key="Home.PinMenuItem" TargetType="MenuItem">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/><Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/><Setter Property="Background" Value="{DynamicResource B.Bg.Raised}"/>
    <Setter Property="MinHeight" Value="32"/><Setter Property="Padding" Value="12,0"/><Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Inside}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="MenuItem">
      <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" CornerRadius="4">
        <DockPanel LastChildFill="True"><TextBlock DockPanel.Dock="Right" Text="{TemplateBinding InputGestureText}" Margin="12,0,0,0" VerticalAlignment="Center" Style="{StaticResource T.Sub}"/>
          <ContentPresenter ContentSource="Header" VerticalAlignment="Center" RecognizesAccessKey="True"/>
        </DockPanel>
      </Border>
    </ControlTemplate></Setter.Value></Setter>
    <Style.Triggers><Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/></Trigger>
      <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/></Trigger>
    </Style.Triggers>
  </Style>
  <!-- 항목 모양은 ItemContainerStyle 대신 이 메뉴 안의 기본 모양으로 준다. ItemContainerStyle은 구분선(Separator)에도 씌우려다
       「MenuItem 모양을 Separator에 쓸 수 없음」 오류로 메뉴가 안 열린다(2026-11-07 관련 메모 줄 우클릭에서 찾음) -->
  <Style x:Key="Home.PinMenu" TargetType="ContextMenu">
    <Style.Resources>
      <Style TargetType="MenuItem" BasedOn="{StaticResource Home.PinMenuItem}"/>
      <!-- 메뉴 안의 구분선은 WPF가 MenuItem.SeparatorStyleKey 이름으로 모양을 찾는다(기본 모양은 테마 색이 아님) -->
      <Style x:Key="{x:Static MenuItem.SeparatorStyleKey}" TargetType="Separator">
        <Setter Property="Margin" Value="8,4"/><Setter Property="Focusable" Value="False"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Separator"><Border Height="1" Background="{DynamicResource B.Border.Muted}"/></ControlTemplate></Setter.Value></Setter>
      </Style>
    </Style.Resources>
    <Setter Property="Background" Value="{DynamicResource B.Bg.Raised}"/><Setter Property="BorderBrush" Value="{DynamicResource B.Border.Default}"/>
    <Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="4"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ContextMenu">
      <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}" CornerRadius="8"><ItemsPresenter/></Border>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Home.TimelineEvent" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Height" Value="10"/><Setter Property="MinHeight" Value="0"/><Setter Property="Padding" Value="0"/>
    <Setter Property="Background" Value="{DynamicResource B.Accent}"/><Setter Property="Foreground" Value="{DynamicResource B.OnAccent}"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Grid><Border Background="{TemplateBinding Background}" CornerRadius="2"/>
        <Border x:Name="Ink" Background="{DynamicResource B.Overlay.Ink}" Opacity="0" CornerRadius="2"/>
        <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
      </Grid><ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Ink" Property="Opacity" Value="0.04"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter TargetName="Ink" Property="Opacity" Value="0.07"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
    <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource B.Accent}"/></Trigger>
      <Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="{DynamicResource B.Accent}"/></Trigger>
    </Style.Triggers>
  </Style>
  <!-- 일정 2판: 월 달력·사이드바·편집 폼. 값은 7·8절과 U4/U13. -->
  <!-- 근태 표·폼: 디자인 2판 U14. 탭은 값 대신 이 쓰임새 스타일을 쓴다. -->
  <Style x:Key="Attendance.Page" TargetType="Grid"/>
  <Style x:Key="Attendance.Header" TargetType="DockPanel"><Setter Property="Height" Value="{DynamicResource F.Height.Header}"/><Setter Property="Margin" Value="16,0,16,0"/></Style>
  <Style x:Key="Attendance.TableHost" TargetType="Grid"><Setter Property="Margin" Value="16,0,16,16"/></Style>
  <Style x:Key="Attendance.Action" TargetType="Button" BasedOn="{StaticResource Btn}"><Setter Property="Height" Value="32"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Attendance.Action.Primary" TargetType="Button" BasedOn="{StaticResource Btn.Primary}"><Setter Property="Height" Value="32"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Attendance.Month" TargetType="TextBlock" BasedOn="{StaticResource T.Title}"><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Margin" Value="4,0"/></Style>
  <Style x:Key="Attendance.Body" TargetType="DockPanel"><Setter Property="Margin" Value="16,0,16,16"/></Style>
  <Style x:Key="Attendance.Field" TargetType="StackPanel"><Setter Property="Margin" Value="0,0,0,12"/></Style>
  <Style x:Key="Attendance.Label" TargetType="TextBlock" BasedOn="{StaticResource T.Body}"><Setter Property="Foreground" Value="{DynamicResource B.Text.Secondary}"/><Setter Property="Margin" Value="0,0,0,8"/></Style>
  <Style x:Key="Attendance.Error" TargetType="TextBlock" BasedOn="{StaticResource T.Sub}"><Setter Property="Foreground" Value="{DynamicResource B.Status.Error.Text}"/><Setter Property="Margin" Value="0,4,0,0"/></Style>
  <Style x:Key="Attendance.SummaryRow" TargetType="DockPanel"><Setter Property="MinHeight" Value="32"/></Style>
  <Style x:Key="Attendance.SummaryChild" TargetType="DockPanel" BasedOn="{StaticResource Attendance.SummaryRow}"><Setter Property="Margin" Value="12,0,0,0"/></Style>
  <!-- 이번 달 요약과 아래 대휴(전체 기간) 사이: 위아래 8 + 선 1 -->
  <Style x:Key="Attendance.SummaryDivider" TargetType="Border"><Setter Property="Height" Value="1"/><Setter Property="Margin" Value="0,8"/><Setter Property="Background" Value="{DynamicResource B.Border.Muted}"/></Style>
  <Style x:Key="Attendance.Note" TargetType="TextBox" BasedOn="{StaticResource Input}"><Setter Property="AcceptsReturn" Value="True"/><Setter Property="TextWrapping" Value="Wrap"/><Setter Property="VerticalScrollBarVisibility" Value="Auto"/></Style>
  <Style x:Key="Attendance.CellText" TargetType="TextBlock" BasedOn="{StaticResource Task.Text}"/>
  <Style x:Key="Attendance.Number" TargetType="TextBlock" BasedOn="{StaticResource Attendance.CellText}"><Setter Property="TextAlignment" Value="Right"/></Style>
  <Style x:Key="Attendance.Row" TargetType="DataGridRow">
    <Setter Property="AutomationProperties.Name" Value="{Binding Note}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="DataGridRow">
      <Border Background="{TemplateBinding Background}"><Grid>
        <DataGridCellsPresenter/>
        <Border x:Name="SelectionMark" Width="3" Height="16" CornerRadius="1.5" HorizontalAlignment="Left" VerticalAlignment="Center" Background="{DynamicResource B.Accent}" Visibility="Collapsed" IsHitTestVisible="False"/>
      </Grid></Border>
      <ControlTemplate.Triggers><Trigger Property="IsSelected" Value="True"><Setter TargetName="SelectionMark" Property="Visibility" Value="Visible"/></Trigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>

    <Setter Property="MinHeight" Value="32"/><Setter Property="Background" Value="{DynamicResource B.Bg.Surface}"/><Setter Property="BorderThickness" Value="0"/><Setter Property="ToolTip" Value="{Binding Problem}"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/></Trigger>
      <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource B.Bg.Selected}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Attendance.Table" TargetType="DataGrid">
    <Setter Property="Background" Value="{DynamicResource B.Bg.Surface}"/><Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/><Setter Property="FontSize" Value="{DynamicResource F.Body}"/><Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="BorderThickness" Value="0"/><Setter Property="HorizontalGridLinesBrush" Value="{DynamicResource B.Border.Muted}"/><Setter Property="GridLinesVisibility" Value="Horizontal"/><Setter Property="HeadersVisibility" Value="Column"/>
    <Setter Property="RowStyle" Value="{StaticResource Attendance.Row}"/><Setter Property="CellStyle" Value="{StaticResource Task.Cell}"/><Setter Property="ColumnHeaderStyle" Value="{StaticResource Task.Header}"/>
    <Setter Property="RowHeight" Value="32"/><Setter Property="ColumnHeaderHeight" Value="32"/>
  </Style>
  <DataTemplate x:Key="Attendance.TableView">
    <DataGrid Style="{DynamicResource Attendance.Table}" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" CanUserDeleteRows="False" CanUserReorderColumns="False" CanUserResizeRows="False" CanUserSortColumns="False" SelectionMode="Single" SelectionUnit="FullRow" AutomationProperties.Name="근태 기록">
      <DataGrid.Columns>
        <DataGridTextColumn Header="날짜" Binding="{Binding Date}" Width="100" ElementStyle="{StaticResource Attendance.CellText}"/>
        <DataGridTextColumn Header="종류" Binding="{Binding Kind}" Width="88" ElementStyle="{StaticResource Attendance.CellText}"/>
        <DataGridTextColumn Header="시작" Binding="{Binding Start}" Width="64" ElementStyle="{StaticResource Attendance.CellText}"/>
        <DataGridTextColumn Header="끝" Binding="{Binding End}" Width="64" ElementStyle="{StaticResource Attendance.CellText}"/>
        <DataGridTextColumn Header="장소" Binding="{Binding Place}" Width="72" ElementStyle="{StaticResource Attendance.CellText}"/>
        <DataGridTextColumn Header="이동" Binding="{Binding Travel}" Width="56" HeaderStyle="{StaticResource Task.HeaderRight}" ElementStyle="{StaticResource Attendance.Number}"/>
        <DataGridTextColumn Header="시간" Binding="{Binding Duration}" Width="64" HeaderStyle="{StaticResource Task.HeaderRight}" ElementStyle="{StaticResource Attendance.Number}"/>
        <DataGridTextColumn Header="메모" Binding="{Binding Note}" Width="*" ElementStyle="{StaticResource Attendance.CellText}"/>
      </DataGrid.Columns>
    </DataGrid>
  </DataTemplate>
  <Style x:Key="Schedule.Page" TargetType="Grid"/>
  <Style x:Key="Schedule.Header" TargetType="DockPanel"><Setter Property="Height" Value="{DynamicResource F.Height.Header}"/><Setter Property="Margin" Value="24,0,16,0"/></Style>
  <Style x:Key="Schedule.Body" TargetType="DockPanel"><Setter Property="Margin" Value="16,0,16,16"/></Style>
  <Style x:Key="Schedule.Month" TargetType="TextBlock" BasedOn="{StaticResource T.Title}"><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Schedule.MonthMove" TargetType="Button" BasedOn="{StaticResource Btn.Icon}"><Setter Property="Margin" Value="0,0,4,0"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Schedule.MonthToday" TargetType="Button" BasedOn="{StaticResource Btn}"><Setter Property="Height" Value="32"/><Setter Property="Margin" Value="0,0,4,0"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Schedule.Weekday" TargetType="TextBlock" BasedOn="{StaticResource T.Sub}"><Setter Property="Height" Value="28"/><Setter Property="Padding" Value="8,6,0,0"/><Setter Property="Foreground" Value="{DynamicResource B.Text.Tertiary}"/></Style>
  <Style x:Key="Schedule.Day" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Padding" Value="0"/><Setter Property="MinHeight" Value="88"/><Setter Property="Background" Value="Transparent"/><Setter Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/><Setter Property="BorderThickness" Value="0,0,1,1"/>
    <Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="VerticalContentAlignment" Value="Top"/><Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Inside}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Grid>
      <Border Background="{TemplateBinding Background}" BorderBrush="{DynamicResource B.Border.Muted}" BorderThickness="{TemplateBinding BorderThickness}"/>
      <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Top"/>
      <Border x:Name="Selection" BorderBrush="{DynamicResource B.Accent}" BorderThickness="1" Visibility="Collapsed" IsHitTestVisible="False"/>
    </Grid><ControlTemplate.Triggers><Trigger Property="Tag" Value="Selected"><Setter TargetName="Selection" Property="Visibility" Value="Visible"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Schedule.DayOff" TargetType="Button" BasedOn="{StaticResource Schedule.Day}"><Setter Property="Background" Value="{DynamicResource B.Cal.DayOff}"/></Style>
  <Style x:Key="Schedule.Today" TargetType="Button" BasedOn="{StaticResource Schedule.Day}"><Setter Property="Background" Value="{DynamicResource B.Bg.Selected}"/></Style>
  <Style x:Key="Schedule.DayHead" TargetType="Grid"><Setter Property="Height" Value="30"/></Style>
  <Style x:Key="Schedule.DateCircle" TargetType="Border"><Setter Property="Width" Value="24"/><Setter Property="Height" Value="24"/><Setter Property="CornerRadius" Value="12"/><Setter Property="Margin" Value="4,6,0,0"/><Setter Property="HorizontalAlignment" Value="Left"/><Setter Property="VerticalAlignment" Value="Top"/></Style>
  <Style x:Key="Schedule.Date" TargetType="TextBlock" BasedOn="{StaticResource T.Body}"><Setter Property="HorizontalAlignment" Value="Center"/><Setter Property="VerticalAlignment" Value="Center"/></Style>

  <Style x:Key="Schedule.Holiday" TargetType="TextBlock" BasedOn="{StaticResource T.Sub}"><Setter Property="Foreground" Value="{DynamicResource B.Status.Error.Text}"/><Setter Property="Margin" Value="34,10,4,0"/><Setter Property="VerticalAlignment" Value="Top"/><Setter Property="TextWrapping" Value="NoWrap"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>
  <Style x:Key="Schedule.Chip" TargetType="Border"><Setter Property="Height" Value="20"/><Setter Property="CornerRadius" Value="2"/><Setter Property="Margin" Value="4,0,4,2"/><Setter Property="Padding" Value="4,0"/><Setter Property="Background" Value="{DynamicResource B.Bg.Subtle}"/></Style>
  <Style x:Key="Schedule.ChipText" TargetType="TextBlock" BasedOn="{StaticResource T.Sub}"><Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="TextWrapping" Value="NoWrap"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>
  <Style x:Key="Schedule.More" TargetType="TextBlock" BasedOn="{StaticResource T.Sub}"><Setter Property="Margin" Value="8,0,4,0"/><Setter Property="TextWrapping" Value="NoWrap"/></Style>
  <Style x:Key="Schedule.Side" TargetType="Grid"/>

  <Style x:Key="Schedule.SideTitle" TargetType="TextBlock" BasedOn="{StaticResource T.Body}"><Setter Property="FontSize" Value="{DynamicResource F.Subtitle}"/><Setter Property="FontWeight" Value="{DynamicResource F.Subtitle.Weight}"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>
  <Style x:Key="Schedule.Add" TargetType="Button" BasedOn="{StaticResource Btn.Icon}"><Setter Property="Margin" Value="8,0,0,0"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Schedule.SideBody" TargetType="DockPanel"><Setter Property="Margin" Value="16,0,16,16"/></Style>
  <Style x:Key="Schedule.Form" TargetType="StackPanel"><Setter Property="Margin" Value="0,0,0,12"/></Style>
  <Style x:Key="Schedule.Field" TargetType="StackPanel"><Setter Property="Margin" Value="0,0,0,12"/></Style>
  <Style x:Key="Schedule.FieldLabel" TargetType="TextBlock" BasedOn="{StaticResource T.Body}"><Setter Property="Foreground" Value="{DynamicResource B.Text.Secondary}"/><Setter Property="Margin" Value="0,0,0,8"/></Style>
  <Style x:Key="Schedule.RangeDash" TargetType="TextBlock" BasedOn="{StaticResource T.Body}"><Setter Property="Foreground" Value="{DynamicResource B.Text.Secondary}"/><Setter Property="Margin" Value="8,0"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Schedule.Error" TargetType="TextBlock" BasedOn="{StaticResource T.Sub}"><Setter Property="Foreground" Value="{DynamicResource B.Status.Error.Text}"/><Setter Property="Margin" Value="0,4,0,0"/></Style>
  <Style x:Key="Schedule.Separator" TargetType="Border"><Setter Property="Height" Value="16"/></Style>
  <Style x:Key="Schedule.EventRow" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Height" Value="Auto"/><Setter Property="MinHeight" Value="32"/><Setter Property="Padding" Value="0"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Border Background="{TemplateBinding Background}" CornerRadius="{DynamicResource F.Radius.Control}"><ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Center"/></Border>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Schedule.EventTime" TargetType="TextBlock" BasedOn="{StaticResource T.CaptionMuted}"><Setter Property="Width" Value="64"/><Setter Property="VerticalAlignment" Value="Top"/><Setter Property="Margin" Value="0,2,0,0"/></Style>
  <Style x:Key="Schedule.EventTitle" TargetType="TextBlock" BasedOn="{StaticResource T.Body}"><Setter Property="TextWrapping" Value="NoWrap"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <!-- 일정 2단계 관련 메모(디자인 README 「일정」): 폼 맨 아래 머리 · 줄 32 · 단추 줄, 일정 · 루틴 줄 끝 개수 -->
  <Style x:Key="Schedule.LinkSection" TargetType="StackPanel"><Setter Property="Margin" Value="0,0,0,12"/></Style>
  <Style x:Key="Schedule.LinkHead" TargetType="TextBlock" BasedOn="{StaticResource Schedule.FieldLabel}"/>
  <Style x:Key="Schedule.LinkRow" TargetType="Button" BasedOn="{StaticResource Schedule.EventRow}"><Setter Property="MinHeight" Value="{DynamicResource F.Height.Control}"/></Style>
  <Style x:Key="Schedule.LinkBody" TargetType="DockPanel"><Setter Property="Margin" Value="8,0"/></Style>
  <Style x:Key="Schedule.LinkIcon" TargetType="TextBlock" BasedOn="{StaticResource T.Icon}"><Setter Property="Foreground" Value="{DynamicResource B.Text.Secondary}"/><Setter Property="Margin" Value="0,0,8,0"/></Style>
  <Style x:Key="Schedule.LinkTitle" TargetType="TextBlock" BasedOn="{StaticResource Schedule.EventTitle}"/>
  <Style x:Key="Schedule.LinkScope" TargetType="TextBlock" BasedOn="{StaticResource T.CaptionMuted}"><Setter Property="Margin" Value="8,0,0,0"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="TextWrapping" Value="NoWrap"/></Style>
  <Style x:Key="Schedule.LinkButtons" TargetType="StackPanel"><Setter Property="Orientation" Value="Horizontal"/><Setter Property="Margin" Value="0,8,0,0"/></Style>
  <Style x:Key="Schedule.LinkChevron" TargetType="TextBlock" BasedOn="{StaticResource T.Icon}"><Setter Property="FontSize" Value="10"/><Setter Property="Foreground" Value="{DynamicResource B.Text.Secondary}"/><Setter Property="Margin" Value="8,0,0,0"/></Style>
  <Style x:Key="Schedule.LinkCount" TargetType="StackPanel"><Setter Property="Orientation" Value="Horizontal"/><Setter Property="Margin" Value="8,0,0,0"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Schedule.LinkCountIcon" TargetType="TextBlock" BasedOn="{StaticResource T.Icon}"><Setter Property="FontSize" Value="{DynamicResource F.Caption}"/><Setter Property="Foreground" Value="{DynamicResource B.Text.Tertiary}"/><Setter Property="Margin" Value="0,0,4,0"/></Style>
  <Style x:Key="Schedule.LinkCountText" TargetType="TextBlock" BasedOn="{StaticResource T.CaptionMuted}"><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <!-- 메모 고르기 창(New-WtModal 위): 목록 240, 두 줄 48, 이미 붙은 메모는 흐린 제목 + 「붙어 있음」으로 고를 수 없음 -->
  <DataTemplate x:Key="Memo.PickItem">
    <StackPanel>
      <DockPanel>
        <TextBlock DockPanel.Dock="Right" Text="붙어 있음" Visibility="{Binding LinkedShown}" Style="{DynamicResource T.CaptionMuted}" Margin="8,0,0,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="PickTitle" Text="{Binding Title}" Style="{DynamicResource T.Body}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
      </DockPanel>
      <TextBlock Text="{Binding Sub}" Style="{DynamicResource T.CaptionMuted}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
    </StackPanel>
    <DataTemplate.Triggers><DataTrigger Binding="{Binding Linked}" Value="True"><Setter TargetName="PickTitle" Property="Foreground" Value="{DynamicResource B.Text.Tertiary}"/></DataTrigger></DataTemplate.Triggers>
  </DataTemplate>
  <Style x:Key="Memo.PickRow" TargetType="ListBoxItem" BasedOn="{StaticResource Row.TwoLine}">
    <Setter Property="IsEnabled" Value="{Binding Selectable}"/>
    <Style.Triggers><Trigger Property="IsEnabled" Value="False"><Setter Property="Background" Value="{DynamicResource B.Bg.Surface}"/><Setter Property="Cursor" Value="Arrow"/></Trigger></Style.Triggers>
  </Style>
  <Style x:Key="Memo.PickList" TargetType="ListBox" BasedOn="{StaticResource List}">
    <Setter Property="ItemTemplate" Value="{StaticResource Memo.PickItem}"/>
    <Setter Property="ItemContainerStyle" Value="{StaticResource Memo.PickRow}"/>
    <Setter Property="Height" Value="240"/>
    <Setter Property="Background" Value="{DynamicResource B.Bg.Surface}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Default}"/>
    <Setter Property="BorderThickness" Value="1"/>
  </Style>
  <Style x:Key="Memo.PickEmpty" TargetType="TextBlock" BasedOn="{StaticResource T.CaptionMuted}"><Setter Property="HorizontalAlignment" Value="Center"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="IsHitTestVisible" Value="False"/></Style>
  <!-- 메모 새 창(New-WtSideWindow): 창 바탕 위 흰 카드(가장자리 8, 위 4), 글 위 24 · 좌우 44(창이 480보다 좁으면 20), 제목 F.Memo.H1 -->
  <Style x:Key="SideWindow.Body" TargetType="Border" BasedOn="{StaticResource Panel.Surface}"><Setter Property="Margin" Value="8,4,8,8"/></Style>
  <Style x:Key="SideWindow.ToolText" TargetType="TextBlock" BasedOn="{StaticResource T.CaptionMuted}"><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Margin" Value="8,0,0,0"/></Style>
  <Style x:Key="SideWindow.ToolIcon" TargetType="TextBlock" BasedOn="{StaticResource T.Icon}"><Setter Property="Foreground" Value="{DynamicResource B.Text.Secondary}"/></Style>
  <Style x:Key="MemoWindow.Text" TargetType="StackPanel"><Setter Property="Margin" Value="44,24,44,24"/><Setter Property="MaxWidth" Value="680"/></Style>
  <Style x:Key="MemoWindow.TextNarrow" TargetType="StackPanel" BasedOn="{StaticResource MemoWindow.Text}"><Setter Property="Margin" Value="20,24,20,24"/></Style>
  <Style x:Key="MemoWindow.Title" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontSize" Value="{DynamicResource F.Memo.H1}"/><Setter Property="FontWeight" Value="{DynamicResource F.Memo.H1.Weight}"/><Setter Property="LineHeight" Value="{DynamicResource F.Memo.H1.LineHeight}"/>
  </Style>
  <Style x:Key="MemoWindow.Meta" TargetType="TextBlock" BasedOn="{StaticResource T.CaptionMuted}"><Setter Property="Margin" Value="0,4,0,12"/></Style>
  <!-- 설정 → 휴무일: 해 이동 줄과 간단한 표(폭 720, 머리 32 · 행 32, 셀 좌우 12, 행 사이 선 B.Border.Muted). 행은 우클릭 · Delete · F2 -->
  <Style x:Key="T.Error" TargetType="TextBlock" BasedOn="{StaticResource T.Sub}"><Setter Property="Foreground" Value="{DynamicResource B.Status.Error.Text}"/></Style>
  <Style x:Key="Holiday.Bar" TargetType="DockPanel"><Setter Property="Width" Value="720"/><Setter Property="HorizontalAlignment" Value="Left"/><Setter Property="Margin" Value="0,4,0,8"/></Style>
  <Style x:Key="Holiday.Year" TargetType="TextBlock" BasedOn="{StaticResource T.Body}"><Setter Property="FontWeight" Value="{DynamicResource F.BodyStrong.Weight}"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Margin" Value="4,0"/></Style>
  <Style x:Key="Table.Simple" TargetType="StackPanel"><Setter Property="Width" Value="720"/><Setter Property="HorizontalAlignment" Value="Left"/></Style>
  <Style x:Key="Table.Head" TargetType="Border"><Setter Property="Height" Value="32"/><Setter Property="BorderBrush" Value="{DynamicResource B.Border.Default}"/><Setter Property="BorderThickness" Value="0,0,0,1"/></Style>
  <Style x:Key="Table.HeadText" TargetType="TextBlock" BasedOn="{StaticResource T.Sub}"><Setter Property="Foreground" Value="{DynamicResource B.Text.Tertiary}"/><Setter Property="Margin" Value="12,0"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Table.Row" TargetType="Border"><Setter Property="MinHeight" Value="32"/><Setter Property="Background" Value="Transparent"/><Setter Property="BorderBrush" Value="{DynamicResource B.Border.Muted}"/><Setter Property="BorderThickness" Value="0,0,0,1"/><Setter Property="Focusable" Value="True"/><Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Inside}"/>
    <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/></Trigger></Style.Triggers>
  </Style>
  <Style x:Key="Table.Cell" TargetType="TextBlock" BasedOn="{StaticResource T.Body}"><Setter Property="Margin" Value="12,0"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="TextWrapping" Value="NoWrap"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>
  <Style x:Key="Table.CellSub" TargetType="TextBlock" BasedOn="{StaticResource Table.Cell}"><Setter Property="FontSize" Value="{DynamicResource F.Caption}"/><Setter Property="Foreground" Value="{DynamicResource B.Text.Secondary}"/></Style>
  <Style x:Key="Table.Empty" TargetType="TextBlock" BasedOn="{StaticResource T.Sub}"><Setter Property="Margin" Value="12,12,0,0"/></Style>
  <!-- 해 · 달 고르기 (달력 머리줄의 해 · 달 단추 아래 펼침 면): 떠 있는 면 + 위 줄 ‹ 2026년 › + 4 × 3 달 칸 60 × 44 -->
  <Style x:Key="Picker.Panel" TargetType="Border"><Setter Property="Background" Value="{DynamicResource B.Bg.Raised}"/><Setter Property="BorderBrush" Value="{DynamicResource B.Border.Default}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="{DynamicResource F.Radius.Overlay}"/><Setter Property="Padding" Value="10,8,10,10"/></Style>
  <Style x:Key="Picker.Head" TargetType="DockPanel"><Setter Property="Height" Value="36"/><Setter Property="Margin" Value="0,0,0,4"/></Style>
  <Style x:Key="Picker.Year" TargetType="TextBlock" BasedOn="{StaticResource T.Body}"><Setter Property="FontWeight" Value="{DynamicResource F.BodyStrong.Weight}"/><Setter Property="HorizontalAlignment" Value="Center"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Picker.Month" TargetType="Button" BasedOn="{StaticResource Btn.Icon}"><Setter Property="Width" Value="60"/><Setter Property="Height" Value="44"/><Setter Property="Margin" Value="2"/><Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/><Setter Property="FontSize" Value="{DynamicResource F.Body}"/></Style>
  <Style x:Key="Picker.Today" TargetType="Button" BasedOn="{StaticResource Btn.Link}"><Setter Property="HorizontalAlignment" Value="Left"/><Setter Property="Margin" Value="0,4,0,0"/></Style>
  <Style x:Key="Picker.MonthSelected" TargetType="Button" BasedOn="{StaticResource Picker.Month}"><Setter Property="Background" Value="{DynamicResource B.Accent}"/><Setter Property="Foreground" Value="{DynamicResource B.OnAccent}"/><Setter Property="FontWeight" Value="{DynamicResource F.BodyStrong.Weight}"/>
    <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource B.Accent.Hover}"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="{DynamicResource B.Accent.Pressed}"/></Trigger></Style.Triggers>
  </Style>
  <!-- 달력 머리줄: 「2026년 11월 ⌄」 단추(글자 자리는 예전 제목과 같게 왼쪽 -8), ‹ 오늘 › 묶음 -->
  <Style x:Key="Schedule.MonthButton" TargetType="Button" BasedOn="{StaticResource Btn.Icon}"><Setter Property="Width" Value="Auto"/><Setter Property="Height" Value="{DynamicResource F.Height.Control}"/><Setter Property="Padding" Value="8,0"/><Setter Property="Margin" Value="-8,0,0,0"/><Setter Property="HorizontalAlignment" Value="Left"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/></Style>
  <Style x:Key="Schedule.MonthChevron" TargetType="TextBlock"><Setter Property="FontFamily" Value="{DynamicResource Font.Icon}"/><Setter Property="FontSize" Value="12"/><Setter Property="Margin" Value="4,0,0,0"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Foreground" Value="{DynamicResource B.Text.Secondary}"/></Style>
  <!-- 일정 줄: 체크 상자 + [시각 칸 64 · 제목 (+ 여러 날이면 둘째 줄 기간)]. 한 줄 32 · 두 줄 48 -->
  <Style x:Key="Schedule.EventBody" TargetType="DockPanel"><Setter Property="Margin" Value="0,6,0,6"/></Style>
  <Style x:Key="Schedule.EventSub" TargetType="TextBlock" BasedOn="{StaticResource T.CaptionMuted}"><Setter Property="TextWrapping" Value="NoWrap"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>
  <Style x:Key="Schedule.EventCheck" TargetType="CheckBox" BasedOn="{StaticResource Check}"><Setter Property="Margin" Value="0,2,10,0"/><Setter Property="VerticalAlignment" Value="Top"/><Setter Property="Background" Value="Transparent"/></Style>
  <!-- 달력 칸: 끝낸 일정 칩 앞의 체크 표시(CheckMark E73E 10), 여러 날 막대(흰 바탕 + 1 B.Border.Default, 주를 넘는 쪽은 열어 둠) -->
  <Style x:Key="Schedule.ChipMark" TargetType="Run"><Setter Property="FontFamily" Value="{DynamicResource Font.Icon}"/><Setter Property="FontSize" Value="10"/></Style>
  <Style x:Key="Schedule.BarLanes" TargetType="StackPanel"><Setter Property="Margin" Value="0,30,0,0"/><Setter Property="VerticalAlignment" Value="Top"/></Style>
  <Style x:Key="Schedule.BarLane" TargetType="Grid"><Setter Property="Height" Value="20"/><Setter Property="Margin" Value="0,0,0,2"/></Style>
  <Style x:Key="Schedule.Bar" TargetType="Border"><Setter Property="Cursor" Value="Hand"/><Setter Property="Height" Value="20"/><Setter Property="Margin" Value="4,0,4,0"/><Setter Property="Padding" Value="3,0"/><Setter Property="VerticalAlignment" Value="Top"/><Setter Property="Background" Value="{DynamicResource B.Bg.Surface}"/><Setter Property="BorderBrush" Value="{DynamicResource B.Border.Default}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="2"/></Style>
  <Style x:Key="Schedule.BarFromPrev" TargetType="Border" BasedOn="{StaticResource Schedule.Bar}"><Setter Property="Margin" Value="0,0,4,0"/><Setter Property="Padding" Value="4,0,3,0"/><Setter Property="BorderThickness" Value="0,1,1,1"/><Setter Property="CornerRadius" Value="0,2,2,0"/></Style>
  <Style x:Key="Schedule.BarToNext" TargetType="Border" BasedOn="{StaticResource Schedule.Bar}"><Setter Property="Margin" Value="4,0,0,0"/><Setter Property="BorderThickness" Value="1,1,0,1"/><Setter Property="CornerRadius" Value="2,0,0,2"/></Style>
  <Style x:Key="Schedule.BarMiddle" TargetType="Border" BasedOn="{StaticResource Schedule.Bar}"><Setter Property="Margin" Value="0"/><Setter Property="Padding" Value="4,0,0,0"/><Setter Property="BorderThickness" Value="0,1,0,1"/><Setter Property="CornerRadius" Value="0"/></Style>
  <Style x:Key="Schedule.RoutineCount" TargetType="TextBlock" BasedOn="{StaticResource T.Sub}"><Setter Property="Foreground" Value="{DynamicResource B.Text.Tertiary}"/><Setter Property="Margin" Value="8,0,0,0"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <!-- 일정 3단계(디자인 README 「일정」): 머리줄 제목 · ‹ 오늘 › · 찾기 · 깔때기 · 보기 전환(메모 탭 모양), 표 · 할 일 줄, 루틴 보기 -->
  <Style x:Key="Schedule.ViewTitle" TargetType="TextBlock" BasedOn="{StaticResource T.Title}"><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="TextWrapping" Value="NoWrap"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>
  <Style x:Key="Schedule.TableNav" TargetType="StackPanel"><Setter Property="Orientation" Value="Horizontal"/><Setter Property="Margin" Value="12,0,0,0"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Schedule.TodayButton" TargetType="Button" BasedOn="{StaticResource Btn}"><Setter Property="Height" Value="{DynamicResource F.Height.Compact}"/><Setter Property="MinHeight" Value="0"/><Setter Property="Margin" Value="4,0"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Schedule.Search" TargetType="Grid"><Setter Property="Width" Value="200"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Schedule.Filter" TargetType="Button" BasedOn="{StaticResource Btn.Icon}"><Setter Property="Margin" Value="4,0,8,0"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Schedule.ViewTab" TargetType="RadioButton">
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Secondary}"/><Setter Property="Background" Value="Transparent"/>
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/><Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Height" Value="{DynamicResource F.Height.Compact}"/><Setter Property="MinWidth" Value="28"/><Setter Property="Padding" Value="0"/><Setter Property="Margin" Value="4,0,0,0"/>
    <Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{StaticResource Focus.Inside}"/><Setter Property="VerticalAlignment" Value="Center"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
      <Grid>
        <Border Background="{TemplateBinding Background}" CornerRadius="{DynamicResource F.Radius.Control}" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <Border x:Name="Line" Height="2" Margin="8,0" VerticalAlignment="Bottom" Background="{DynamicResource B.Accent}" Visibility="Collapsed"/>
      </Grid>
      <ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="Line" Property="Visibility" Value="Visible"/></Trigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/></Trigger>
      <Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="{DynamicResource B.Fill.Pressed.Surface}"/></Trigger>
      <Trigger Property="IsChecked" Value="True"><Setter Property="Background" Value="{DynamicResource B.Fill.Hover.Surface}"/><Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Schedule.ViewTabText" TargetType="RadioButton" BasedOn="{StaticResource Schedule.ViewTab}"><Setter Property="Padding" Value="12,0"/><Setter Property="Margin" Value="0"/></Style>
  <Style x:Key="Schedule.ViewTabIcon" TargetType="TextBlock" BasedOn="{StaticResource T.Icon}"><Setter Property="Width" Value="28"/><Setter Property="TextAlignment" Value="Center"/></Style>
  <Style x:Key="Schedule.TableHead" TargetType="Border" BasedOn="{StaticResource Table.Head}"><Setter Property="Padding" Value="0,0,12,0"/></Style>
  <Style x:Key="Schedule.TableCheck" TargetType="CheckBox" BasedOn="{StaticResource Check}"><Setter Property="Margin" Value="12,0,0,0"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="HorizontalAlignment" Value="Left"/><Setter Property="Background" Value="Transparent"/></Style>
  <Style x:Key="Schedule.TableRoutineIcon" TargetType="TextBlock" BasedOn="{StaticResource T.Icon}"><Setter Property="FontSize" Value="{DynamicResource F.Caption}"/><Setter Property="Foreground" Value="{DynamicResource B.Text.Tertiary}"/><Setter Property="Margin" Value="0,0,6,0"/></Style>
  <Style x:Key="Schedule.TableMemoIcon" TargetType="TextBlock" BasedOn="{StaticResource T.Icon}"><Setter Property="FontSize" Value="{DynamicResource F.Caption}"/><Setter Property="Foreground" Value="{DynamicResource B.Text.Tertiary}"/><Setter Property="Margin" Value="8,0,4,0"/></Style>
  <Style x:Key="Schedule.TableMeta" TargetType="TextBlock" BasedOn="{StaticResource T.CaptionMuted}"><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Margin" Value="8,0,0,0"/></Style>
  <Style x:Key="Schedule.TableWarn" TargetType="TextBlock" BasedOn="{StaticResource T.Icon}"><Setter Property="FontSize" Value="{DynamicResource F.Caption}"/><Setter Property="Foreground" Value="{DynamicResource B.Status.Error.Icon}"/><Setter Property="Margin" Value="0,0,4,0"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <!-- 할 일 색(디자인 README 「일정」): 배지 = 높이 20 · 모서리 4 · F.Caption, 연한 상태 바탕 + 상태 글자. 기한 지남 = 오류 · 오늘 = 정보 · 마감 임박 = 경고 -->
  <Style x:Key="Schedule.CountBadge" TargetType="Border"><Setter Property="Height" Value="20"/><Setter Property="CornerRadius" Value="{DynamicResource F.Radius.Control}"/><Setter Property="Padding" Value="8,0"/><Setter Property="Margin" Value="8,0,0,0"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Background" Value="{DynamicResource B.Status.Info.Bg}"/></Style>
  <Style x:Key="Schedule.CountBadgeText" TargetType="TextBlock" BasedOn="{StaticResource T.Sub}"><Setter Property="Foreground" Value="{DynamicResource B.Status.Info.Text}"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Schedule.DueBadge" TargetType="Border"><Setter Property="Height" Value="20"/><Setter Property="CornerRadius" Value="{DynamicResource F.Radius.Control}"/><Setter Property="Padding" Value="0"/><Setter Property="HorizontalAlignment" Value="Left"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Background" Value="Transparent"/></Style>
  <Style x:Key="Schedule.TagChip" TargetType="Border"><Setter Property="Height" Value="20"/><Setter Property="CornerRadius" Value="{DynamicResource F.Radius.Control}"/><Setter Property="Padding" Value="8,0"/><Setter Property="Margin" Value="0,0,4,0"/><Setter Property="Background" Value="{DynamicResource B.Bg.Selected}"/></Style>
  <Style x:Key="Schedule.TagChipText" TargetType="TextBlock" BasedOn="{StaticResource T.Sub}"><Setter Property="Foreground" Value="{DynamicResource B.Accent.Text}"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="TextWrapping" Value="NoWrap"/></Style>
  <Style x:Key="Schedule.TableRow" TargetType="ListBoxItem" BasedOn="{StaticResource Row}"><Setter Property="Padding" Value="0"/></Style>
  <!-- 표 · 할 일 줄: 체크 40 · 날짜 120 · 시각 80 · 제목(나머지) · 태그 140 · 기한 88. IsHead면 할 일 묶음 머리(펼침 단추 · 이름 · 개수 배지) -->
  <DataTemplate x:Key="Schedule.TableItem">
    <Grid MinHeight="32">
      <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition Width="120"/><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/><ColumnDefinition Width="140"/><ColumnDefinition Width="88"/></Grid.ColumnDefinitions>
      <StackPanel x:Name="Head" Grid.ColumnSpan="6" Orientation="Horizontal" Visibility="Collapsed">
        <TextBlock Text="{Binding HeadGlyph}" Style="{DynamicResource Schedule.ViewTabIcon}" FontSize="10" Margin="6,0" Foreground="{DynamicResource B.Text.Secondary}"/>
        <TextBlock Text="{Binding HeadName}" VerticalAlignment="Center" Style="{DynamicResource T.Body}" FontWeight="{DynamicResource F.BodyStrong.Weight}"/>
        <Border x:Name="HeadBadge" Style="{DynamicResource Schedule.CountBadge}"><TextBlock x:Name="HeadCount" Text="{Binding HeadCount}" Style="{DynamicResource Schedule.CountBadgeText}"/></Border>
      </StackPanel>
      <CheckBox x:Name="Check" Grid.Column="0" Style="{DynamicResource Schedule.TableCheck}" IsChecked="{Binding Done, Mode=OneWay}" IsEnabled="{Binding CanCheck}" ToolTip="{Binding CheckTip}" AutomationProperties.Name="{Binding CheckName}" ToolTipService.ShowOnDisabled="True"/>
      <TextBlock x:Name="DateCell" Grid.Column="1" Text="{Binding DateText}" Style="{DynamicResource Table.CellSub}"/>
      <TextBlock x:Name="TimeCell" Grid.Column="2" Text="{Binding TimeText}" Style="{DynamicResource Table.CellSub}"/>
      <DockPanel x:Name="TitleCell" Grid.Column="3" Margin="12,0">
        <TextBlock DockPanel.Dock="Left" Text="&#xE8EE;" Visibility="{Binding RoutineShown}" Style="{DynamicResource Schedule.TableRoutineIcon}"/>
        <TextBlock DockPanel.Dock="Right" Text="{Binding MemoCount}" Visibility="{Binding MemoShown}" Style="{DynamicResource Schedule.TableMeta}" Margin="0"/>
        <TextBlock DockPanel.Dock="Right" Text="&#xE70B;" Visibility="{Binding MemoShown}" Style="{DynamicResource Schedule.TableMemoIcon}"/>
        <TextBlock DockPanel.Dock="Right" Text="{Binding Progress}" Visibility="{Binding ProgressShown}" Style="{DynamicResource Schedule.TableMeta}"/>
        <TextBlock x:Name="TitleText" Text="{Binding Title}" Style="{DynamicResource Table.Cell}" Margin="0"/>
      </DockPanel>
      <ItemsControl x:Name="TagCell" Grid.Column="4" ItemsSource="{Binding Tags}" Margin="12,0" VerticalAlignment="Center" Focusable="False">
        <ItemsControl.ItemsPanel><ItemsPanelTemplate><StackPanel Orientation="Horizontal"/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
        <ItemsControl.ItemTemplate><DataTemplate><Border Style="{DynamicResource Schedule.TagChip}"><TextBlock Text="{Binding}" Style="{DynamicResource Schedule.TagChipText}"/></Border></DataTemplate></ItemsControl.ItemTemplate>
      </ItemsControl>
      <Border x:Name="DueCell" Grid.Column="5" Margin="12,0,0,0" Style="{DynamicResource Schedule.DueBadge}">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="&#xE814;" Visibility="{Binding DueWarn}" Style="{DynamicResource Schedule.TableWarn}"/>
          <TextBlock x:Name="DueText" Text="{Binding DueText}" Style="{DynamicResource Table.CellSub}" Margin="0"/>
        </StackPanel>
      </Border>
    </Grid>
    <DataTemplate.Triggers>
      <DataTrigger Binding="{Binding IsHead}" Value="True">
        <Setter TargetName="Head" Property="Visibility" Value="Visible"/>
        <Setter TargetName="Check" Property="Visibility" Value="Collapsed"/><Setter TargetName="DateCell" Property="Visibility" Value="Collapsed"/><Setter TargetName="TimeCell" Property="Visibility" Value="Collapsed"/>
        <Setter TargetName="TitleCell" Property="Visibility" Value="Collapsed"/><Setter TargetName="TagCell" Property="Visibility" Value="Collapsed"/><Setter TargetName="DueCell" Property="Visibility" Value="Collapsed"/>
      </DataTrigger>
      <DataTrigger Binding="{Binding Group}" Value="overdue"><Setter TargetName="HeadBadge" Property="Background" Value="{DynamicResource B.Status.Error.Bg}"/><Setter TargetName="HeadCount" Property="Foreground" Value="{DynamicResource B.Status.Error.Text}"/></DataTrigger>
      <DataTrigger Binding="{Binding Group}" Value="soon"><Setter TargetName="HeadBadge" Property="Background" Value="{DynamicResource B.Status.Warning.Bg}"/><Setter TargetName="HeadCount" Property="Foreground" Value="{DynamicResource B.Status.Warning.Text}"/></DataTrigger>
      <DataTrigger Binding="{Binding Done}" Value="True"><Setter TargetName="TitleText" Property="Foreground" Value="{DynamicResource B.Text.Tertiary}"/></DataTrigger>
      <DataTrigger Binding="{Binding DueStrong}" Value="True"><Setter TargetName="DueText" Property="Foreground" Value="{DynamicResource B.Text.Primary}"/></DataTrigger>
      <DataTrigger Binding="{Binding DueKind}" Value="over"><Setter TargetName="DueCell" Property="Background" Value="{DynamicResource B.Status.Error.Bg}"/><Setter TargetName="DueCell" Property="Padding" Value="6,0"/><Setter TargetName="DueText" Property="Foreground" Value="{DynamicResource B.Status.Error.Text}"/></DataTrigger>
      <DataTrigger Binding="{Binding DueKind}" Value="soon"><Setter TargetName="DueCell" Property="Background" Value="{DynamicResource B.Status.Warning.Bg}"/><Setter TargetName="DueCell" Property="Padding" Value="6,0"/><Setter TargetName="DueText" Property="Foreground" Value="{DynamicResource B.Status.Warning.Text}"/></DataTrigger>
    </DataTemplate.Triggers>
  </DataTemplate>
  <Style x:Key="Schedule.TableList" TargetType="ListBox" BasedOn="{StaticResource List}"><Setter Property="ItemContainerStyle" Value="{StaticResource Schedule.TableRow}"/><Setter Property="ItemTemplate" Value="{StaticResource Schedule.TableItem}"/></Style>
  <!-- 루틴 보기 줄: 이름(나머지) · 규칙 220 · 시각 72 · 오늘 72 · 메모 60 -->
  <DataTemplate x:Key="Schedule.RoutineItem">
    <Grid MinHeight="32">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="220"/><ColumnDefinition Width="72"/><ColumnDefinition Width="72"/><ColumnDefinition Width="60"/></Grid.ColumnDefinitions>
      <DockPanel Margin="12,0"><TextBlock Text="&#xE8EE;" Style="{DynamicResource Schedule.TableRoutineIcon}"/><TextBlock x:Name="RoutineName" Text="{Binding Title}" Style="{DynamicResource Table.Cell}" Margin="0"/></DockPanel>
      <TextBlock Grid.Column="1" Text="{Binding RuleText}" Style="{DynamicResource Table.CellSub}"/>
      <TextBlock Grid.Column="2" Text="{Binding TimeText}" Style="{DynamicResource Table.CellSub}"/>
      <TextBlock x:Name="RoutineToday" Grid.Column="3" Text="{Binding TodayText}" Style="{DynamicResource Table.CellSub}"/>
      <StackPanel Grid.Column="4" Orientation="Horizontal" Margin="12,0" Visibility="{Binding MemoShown}"><TextBlock Text="&#xE70B;" Style="{DynamicResource Schedule.TableMemoIcon}" Margin="0,0,4,0"/><TextBlock Text="{Binding MemoCount}" Style="{DynamicResource Schedule.TableMeta}" Margin="0"/></StackPanel>
    </Grid>
    <DataTemplate.Triggers>
      <DataTrigger Binding="{Binding Problem}" Value="True"><Setter TargetName="RoutineName" Property="Foreground" Value="{DynamicResource B.Text.Disabled}"/></DataTrigger>
      <DataTrigger Binding="{Binding TodayStrong}" Value="True"><Setter TargetName="RoutineToday" Property="Foreground" Value="{DynamicResource B.Text.Primary}"/></DataTrigger>
    </DataTemplate.Triggers>
  </DataTemplate>
  <Style x:Key="Schedule.RoutineList" TargetType="ListBox" BasedOn="{StaticResource List}"><Setter Property="ItemContainerStyle" Value="{StaticResource Schedule.TableRow}"/><Setter Property="ItemTemplate" Value="{StaticResource Schedule.RoutineItem}"/></Style>
  <PopupAnimation x:Key="{x:Static SystemParameters.MenuPopupAnimationKey}">None</PopupAnimation>
  <PopupAnimation x:Key="{x:Static SystemParameters.ToolTipPopupAnimationKey}">None</PopupAnimation>
  <Style x:Key="ToolTip" TargetType="ToolTip">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Caption}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text.Primary}"/>
    <Setter Property="Background" Value="{DynamicResource B.Bg.Surface}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border.Default}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="8,6"/>
    <Setter Property="MaxWidth" Value="{DynamicResource F.ToolTip.MaxWidth}"/>
    <Setter Property="HasDropShadow" Value="False"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToolTip">
      <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4" Padding="{TemplateBinding Padding}">
        <ContentPresenter TextBlock.LineHeight="{DynamicResource F.Caption.LineHeight}">
          <ContentPresenter.Resources><Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style></ContentPresenter.Resources>
        </ContentPresenter>
      </Border>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="ToolTip" BasedOn="{StaticResource ToolTip}"/>

</ResourceDictionary>
'@

$script:styles = $null

# 스타일 사전 (처음 부를 때 한 번 만든다)
# 창 짜임 XAML도 공통 UI에서만 모양을 정한다. 이벤트와 상태는 Shell이 맡는다.
function Get-WtShellXaml {
@'
<Window {NS}
    Title="WorkTool" Style="{DynamicResource Shell.Window}"
    WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True" ResizeMode="CanResize"
    Background="Transparent" UseLayoutRounding="True" SnapsToDevicePixels="True"
    TextOptions.TextFormattingMode="Ideal"
    FontFamily="{DynamicResource Font.UI}" FontSize="{DynamicResource F.Body}" Foreground="{DynamicResource B.Text}">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="32" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Border Background="{DynamicResource B.Bg.Canvas}">
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <DockPanel x:Name="TitleBar" Height="{DynamicResource F.Chrome.Height}" Background="{DynamicResource B.Bg.Canvas}">
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <Button x:Name="MinButton" Style="{DynamicResource Btn.Chrome}" WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="최소화" AutomationProperties.Name="최소화">
            <TextBlock Text="&#xE921;" Style="{DynamicResource T.Icon}" FontSize="10"/>
          </Button>
          <Button x:Name="MaxButton" Style="{DynamicResource Btn.Chrome}" WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="최대화" AutomationProperties.Name="최대화">
            <TextBlock x:Name="MaxGlyph" Text="&#xE922;" Style="{DynamicResource T.Icon}" FontSize="10"/>
          </Button>
          <Button x:Name="CloseButton" Style="{DynamicResource Btn.Close}" WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="닫기" AutomationProperties.Name="닫기">
            <TextBlock Text="&#xE8BB;" Style="{DynamicResource T.Icon}" FontSize="10"/>
          </Button>
        </StackPanel>
        <StackPanel Orientation="Horizontal">
          <Border x:Name="BrandLogo" Style="{DynamicResource Shell.Brand}"><TextBlock Text="W" Style="{DynamicResource Shell.BrandLetter}"/></Border>
          <TextBlock Text="WorkTool" Style="{DynamicResource T.Sub}" Margin="8,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
      </DockPanel>
      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions><ColumnDefinition x:Name="NavColumn" Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border x:Name="NavBorder" Width="{DynamicResource F.Nav.Width}" Background="{DynamicResource B.Bg.Canvas}">
          <DockPanel>
            <Grid DockPanel.Dock="Top" Height="40">
              <Button x:Name="CollapseButton" Style="{DynamicResource Btn.Canvas}" HorizontalAlignment="Left" Margin="12,0,0,0" ToolTip="메뉴 접기/펼치기 (Ctrl+B)" AutomationProperties.Name="메뉴 접기/펼치기">
                <TextBlock Text="&#xE700;" Style="{DynamicResource T.Icon}"/>
              </Button>
            </Grid>
            <StackPanel x:Name="FooterPanel" DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Left" Margin="12,8,0,12">
              <Button x:Name="HelpButton" Style="{DynamicResource Btn.NavFooter}" ToolTip="도움말" AutomationProperties.Name="도움말" Margin="0,0,8,0">
                <TextBlock Text="&#xE897;" Style="{DynamicResource T.Icon}"/>
              </Button>
              <Button x:Name="SettingsButton" Style="{DynamicResource Btn.NavFooter}" ToolTip="설정" AutomationProperties.Name="설정">
                <TextBlock Text="&#xE713;" Style="{DynamicResource T.Icon}"/>
              </Button>
            </StackPanel>
            <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
              <StackPanel x:Name="NavPanel" Margin="8,0,8,0"/>
            </ScrollViewer>
          </DockPanel>
        </Border>
        <Grid Grid.Column="1" Margin="0,0,8,8">
          <ContentControl x:Name="WarmHost" Focusable="False" Visibility="Hidden" IsHitTestVisible="False"/>
          <ContentControl x:Name="PageHost" Focusable="False"/>
        </Grid>
      </Grid>
      <Border x:Name="Frame" Grid.RowSpan="2" BorderBrush="{DynamicResource B.Border.Default}" BorderThickness="1" IsHitTestVisible="False"/>
    </Grid>
  </Border>
</Window>
'@
}

function Get-WtStyleDictionary {
    if (-not $script:styles) {
        foreach ($targetType in [System.Windows.FrameworkElement], [System.Windows.FrameworkContentElement]) {
            if ([System.Windows.Controls.ToolTipService]::InitialShowDelayProperty.GetMetadata($targetType).DefaultValue -ne 400) {
                [System.Windows.Controls.ToolTipService]::InitialShowDelayProperty.OverrideMetadata($targetType, [System.Windows.FrameworkPropertyMetadata]::new(400))
            }
            if ([System.Windows.Controls.ToolTipService]::BetweenShowDelayProperty.GetMetadata($targetType).DefaultValue -ne 100) {
                [System.Windows.Controls.ToolTipService]::BetweenShowDelayProperty.OverrideMetadata($targetType, [System.Windows.FrameworkPropertyMetadata]::new(100))
            }
        }
        $script:styles = [System.Windows.Markup.XamlReader]::Parse($script:stylesXaml.Replace('{NS}', $script:ns))
    }
    $script:styles
}

# XAML 문자열을 요소로 만든다. 맨 앞 태그에 {NS}를 쓰면 기본 이름공간으로 바뀐다.
function ConvertFrom-WtXaml([string]$Xaml) {
    [System.Windows.Markup.XamlReader]::Parse($Xaml.Replace('{NS}', $script:ns))
}

# x:Name을 붙인 요소들을 이름 → 요소 사전으로 돌려준다
function Get-WtNamedElements($Root, [string]$Xaml) {
    $map = @{}
    foreach ($m in [regex]::Matches($Xaml, 'x:Name="([A-Za-z0-9_]+)"')) {
        $name = $m.Groups[1].Value
        $map[$name] = $Root.FindName($name)
    }
    $map
}

function Set-WtStyle($Element, [string]$Key) {
    $Element.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, $Key)
}

# 의존 속성에 테마 리소스를 건다. 예: Set-WtBrush $tb 'Foreground' 'B.SubText'
function Set-WtResource($Element, [string]$Property, [string]$Key) {
    $field = $Element.GetType().GetField("${Property}Property",
        [System.Reflection.BindingFlags]'Public, Static, FlattenHierarchy')
    if (-not $field) { throw "$($Element.GetType().Name)에 $Property 속성이 없습니다." }
    $Element.SetResourceReference($field.GetValue($null), $Key)
}

function New-WtText([string]$Text, [string]$Style = 'T.Body') {
    $t = [System.Windows.Controls.TextBlock]::new()
    $t.Text = $Text
    Set-WtStyle $t $Style
    $t
}

# 아이콘 글꼴(Segoe Fluent Icons / MDL2)의 글자 하나
function New-WtIcon([int]$Code) {
    $t = [System.Windows.Controls.TextBlock]::new()
    $t.Text = [string][char]$Code
    Set-WtStyle $t 'T.Icon'
    $t
}

function New-WtStack([ValidateSet('Vertical', 'Horizontal')][string]$Orientation = 'Vertical', [double]$Gap = 0) {
    $p = [System.Windows.Controls.StackPanel]::new()
    $p.Orientation = $Orientation
    $p.Tag = $Gap
    $p
}

# 쌓기 패널에 요소를 넣는다. 패널 Tag의 간격만큼 앞에 여백을 둔다.
function Add-WtChild($Panel, $Child) {
    $gap = if ($Panel.Tag -is [double]) { [double]$Panel.Tag } else { 0 }
    if ($Panel.Children.Count -gt 0 -and $gap -gt 0 -and $Child -is [System.Windows.FrameworkElement]) {
        $m = $Child.Margin
        if ($Panel.Orientation -eq 'Horizontal') {
            $Child.Margin = [System.Windows.Thickness]::new($m.Left + $gap, $m.Top, $m.Right, $m.Bottom)
        } else {
            $Child.Margin = [System.Windows.Thickness]::new($m.Left, $m.Top + $gap, $m.Right, $m.Bottom)
        }
    }
    [void]$Panel.Children.Add($Child)
    $Child
}

function New-WtCard {
    $b = [System.Windows.Controls.Border]::new()
    Set-WtStyle $b 'Card'
    $b
}

# 카드 머리: 제목(+ 개수) 왼쪽, 오른쪽에 링크 버튼 하나 (선택)
function New-WtCardHeader([string]$Title, [string]$Count, [string]$LinkText, [string]$LinkPage) {
    $g = [System.Windows.Controls.DockPanel]::new()
    $g.LastChildFill = $true
    $g.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    if ($LinkText) {
        $b = New-WtButton $LinkText -Kind Link
        $b.Tag = $LinkPage
        $b.Add_Click({ param($s, $e) Open-WtPage -Id $s.Tag })
        [System.Windows.Controls.DockPanel]::SetDock($b, 'Right')
        [void]$g.Children.Add($b)
    }
    # PowerShell 변수는 대소문자를 가리지 않는다: $title로 쓰면 [string]$Title에 들어가 글자로 바뀐다
    $head = New-WtText $Title 'T.H2'
    if ($Count) {
        $run = [System.Windows.Documents.Run]::new("  $Count")
        $run.FontWeight = 'Normal'
        $run.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'B.SubText')
        $head.Inlines.Add($run)
    }
    $head.VerticalAlignment = 'Center'
    [void]$g.Children.Add($head)
    $g
}

# 버튼. $Kind: Default · Primary · Danger · Icon · Link
function New-WtButton([string]$Text, [string]$Kind = 'Default', [int]$Icon = 0, [string]$ToolTip) {
    $b = [System.Windows.Controls.Button]::new()
    switch ($Kind) {
        'Primary' { Set-WtStyle $b 'Btn.Primary' }
        'Danger' { Set-WtStyle $b 'Btn.Danger' }
        'Icon' { Set-WtStyle $b 'Btn.Icon' }
        'Link' { Set-WtStyle $b 'Btn.Link' }
        default { Set-WtStyle $b 'Btn' }
    }
    $b.Content = New-WtButtonContent $Text $Icon
    if ($ToolTip) { $b.ToolTip = $ToolTip }
    $b
}

# 버튼 안 내용: 아이콘 + 글자 (둘 중 하나만 있어도 됨). 누른 뒤 글자를 바꿀 때도 쓴다 (예: 복사 → 복사됨)
function New-WtButtonContent([string]$Text, [int]$Icon = 0) {
    if ($Icon -and $Text) {
        $row = New-WtStack Horizontal 8
        [void](Add-WtChild $row (New-WtIcon $Icon))
        $label = [System.Windows.Controls.TextBlock]::new()
        $label.Text = $Text
        $label.VerticalAlignment = 'Center'
        [void](Add-WtChild $row $label)
        return $row
    }
    if ($Icon) { return New-WtIcon $Icon }
    $Text
}

# 나눔 버튼: 여러 개 중 하나를 고르는 버튼 묶음 (예: 미리보기 | 원문, 작게 | 보통 | 크게)
# $Options: @(@('값', '글'), ...). 고르면 & $OnChange '값'. $Group은 화면 안에서 겹치지 않는 이름
function New-WtSegmented([object[]]$Options, [string]$Selected, [string]$Group, [scriptblock]$OnChange) {
    $box = [System.Windows.Controls.Border]::new()
    Set-WtResource $box 'Background' 'B.Chip'
    Set-WtResource $box 'CornerRadius' 'F.Radius.Control'
    $box.Padding = [System.Windows.Thickness]::new(4)
    $box.HorizontalAlignment = 'Left'
    $row = New-WtStack Horizontal 4
    foreach ($o in $Options) {
        $rb = [System.Windows.Controls.RadioButton]::new()
        Set-WtStyle $rb 'Seg'
        $rb.GroupName = $Group
        $rb.Content = $o[1]
        $rb.Tag = @{ Value = $o[0]; OnChange = $OnChange }
        $rb.IsChecked = ($o[0] -eq $Selected)
        $rb.Add_Checked({ param($s, $e) & $s.Tag.OnChange $s.Tag.Value })
        [void](Add-WtChild $row $rb)
    }
    $box.Child = $row
    $box
}

# 검색 칸: 돋보기 + 비어 있을 때 안내 글. @{ Root = 화면에 넣을 요소; Box = TextBox } 를 돌려준다
# -Compact: 머리줄에 넣는 높이 28 칸
function New-WtSearchBox([string]$Hint = '검색', [switch]$Compact) {
    $g = [System.Windows.Controls.Grid]::new()
    $box = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $box 'Input'
    if ($Compact) { Set-WtResource $box 'MinHeight' 'F.Height.Compact'; Set-WtResource $box 'Height' 'F.Height.Compact' }
    $box.Padding = [System.Windows.Thickness]::new(32, 0, 10, 0)
    $icon = New-WtIcon 0xE721
    Set-WtResource $icon 'Foreground' 'B.Text.Tertiary'
    Set-WtResource $icon 'FontSize' 'F.Body'
    $icon.HorizontalAlignment = 'Left'
    $icon.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
    $icon.IsHitTestVisible = $false
    $hintText = New-WtText $Hint 'T.Sub'   # $hint로 쓰면 [string]$Hint와 같은 변수가 된다
    $hintText.VerticalAlignment = 'Center'
    $hintText.Margin = [System.Windows.Thickness]::new(32, 0, 0, 0)
    Set-WtResource $hintText 'Foreground' 'B.Text.Tertiary'
    Set-WtResource $hintText 'FontSize' 'F.Body'
    $hintText.IsHitTestVisible = $false
    $box.Tag = $hintText
    $box.Add_TextChanged({ param($s, $e) $s.Tag.Visibility = if ($s.Text) { 'Collapsed' } else { 'Visible' } })
    [void]$g.Children.Add($box)
    [void]$g.Children.Add($icon)
    [void]$g.Children.Add($hintText)
    @{ Root = $g; Box = $box }
}

# 작은 칩 표시. $Bg/$Fg는 테마 리소스 이름 (예: 'Att.WorkBg', 'Att.Work')
function New-WtTag([string]$Text, [string]$Bg = 'Bg.Selected', [string]$Fg = 'Accent.Text', [int]$Icon = 0) {
    $b = [System.Windows.Controls.Border]::new()
    Set-WtStyle $b 'Chip'
    $b.VerticalAlignment = 'Center'
    $b.HorizontalAlignment = 'Left'
    Set-WtResource $b 'Background' "B.$Bg"
    $row = New-WtStack Horizontal 4
    if ($Icon) {
        $i = New-WtIcon $Icon
        Set-WtResource $i 'FontSize' 'F.Small'
        Set-WtResource $i 'Foreground' "B.$Fg"
        [void](Add-WtChild $row $i)
    }
    $t = New-WtText $Text 'T.Sub'
    Set-WtResource $t 'Foreground' "B.$Fg"
    $t.FontWeight = 'Normal'
    $t.TextWrapping = 'NoWrap'
    [void](Add-WtChild $row $t)
    $b.Child = $row
    $b
}

# 조건 칩: 텍스트 + 오른쪽 20×24 삭제 영역. 호출자는 Remove.Click에 해제 동작을 붙인다.
function New-WtFilterChip([string]$Text) {
    $root = [System.Windows.Controls.Border]::new()
    Set-WtStyle $root 'Chip.Filter'
    $layers = [System.Windows.Controls.Grid]::new()
    $outline = [System.Windows.Controls.Border]::new()
    Set-WtResource $outline 'CornerRadius' 'F.Radius.Control'
    Set-WtResource $outline 'BorderBrush' 'B.Border.Default'
    $outline.BorderThickness = [System.Windows.Thickness]::new(1)
    $outline.IsHitTestVisible = $false
    [void]$layers.Children.Add($outline)
    $row = New-WtStack Horizontal 4
    $row.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $label = New-WtText $Text 'T.Sub'
    Set-WtResource $label 'Foreground' 'B.Text.Primary'
    $label.VerticalAlignment = 'Center'
    $label.TextWrapping = 'NoWrap'
    [void](Add-WtChild $row $label)
    $remove = [System.Windows.Controls.Button]::new()
    Set-WtStyle $remove 'Chip.Remove'
    $remove.ToolTip = $Text
    [System.Windows.Automation.AutomationProperties]::SetName($remove, $Text)
    [void](Add-WtChild $row $remove)
    [void]$layers.Children.Add($row)
    $root.Child = $layers
    @{ Root = $root; Remove = $remove }
}

# 숫자 칸: 이름(점 색) + 큰 숫자 + 단위
function New-WtStatTile([string]$Label, [string]$Value, [string]$Unit, [string]$DotKey = 'Accent') {
    $tile = [System.Windows.Controls.Border]::new()
    Set-WtStyle $tile 'Tile'
    $col = New-WtStack Vertical 2
    $head = New-WtStack Horizontal 6
    $dot = [System.Windows.Shapes.Ellipse]::new()
    $dot.Width = 8; $dot.Height = 8
    $dot.VerticalAlignment = 'Center'
    Set-WtResource $dot 'Fill' "B.$DotKey"
    [void](Add-WtChild $head $dot)
    [void](Add-WtChild $head (New-WtText $Label 'T.Sub'))
    [void](Add-WtChild $col $head)
    $num = New-WtText $Value 'T.Number'
    $run = [System.Windows.Documents.Run]::new(" $Unit")
    $run.SetResourceReference([System.Windows.Documents.TextElement]::FontSizeProperty, 'F.Small')
    $run.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'B.SubText')
    $run.FontWeight = 'Normal'
    $num.Inlines.Add($run)
    [void](Add-WtChild $col $num)
    $tile.Child = $col
    $tile
}

# 화면 맨 위: 작은 설명(선택) + 큰 제목 + 오른쪽 요소(선택)
function New-WtPageHeader([string]$Title, [string]$Sub, $Right) {
    $d = [System.Windows.Controls.DockPanel]::new()
    $d.Margin = [System.Windows.Thickness]::new(8, 12, 8, 12)
    if ($Right) {
        [System.Windows.Controls.DockPanel]::SetDock($Right, 'Right')
        $Right.VerticalAlignment = 'Bottom'
        [void]$d.Children.Add($Right)
    }
    $col = New-WtStack Vertical 4
    if ($Sub) { [void](Add-WtChild $col (New-WtText $Sub 'T.Sub')) }
    [void](Add-WtChild $col (New-WtText $Title 'T.Title'))
    [void]$d.Children.Add($col)
    $d
}

# 화면 하나의 바깥 틀: 스크롤 + 안쪽 여백. 돌려준 패널에 내용을 넣는다.
# -Fill: 바깥 스크롤 없이 창 높이를 채운다. 목록 · 본문처럼 스스로 스크롤하는 요소가 있는 화면에 쓴다.
#        돌려준 DockPanel에 머리글을 Top으로 붙이고, 마지막에 넣은 요소가 남는 공간을 채운다.
function New-WtPage([switch]$Fill) {
    if ($Fill) {
        $dock = [System.Windows.Controls.DockPanel]::new()
        $dock.LastChildFill = $true
        return @{ Root = $dock; Panel = $dock }
    }
    $sv = [System.Windows.Controls.ScrollViewer]::new()
    $sv.VerticalScrollBarVisibility = 'Auto'
    $sv.HorizontalScrollBarVisibility = 'Disabled'
    $sv.Focusable = $false
    $panel = New-WtStack Vertical 8
    $sv.Content = $panel
    @{ Root = $sv; Panel = $panel }
}

# 카드 안 한 줄: 구분선 위에 왼쪽부터 요소들을 차례로 놓는다. 마지막 요소가 남는 폭을 채운다.
function New-WtListRow([object[]]$Parts, [double]$Gap = 14) {
    $b = [System.Windows.Controls.Border]::new()
    Set-WtStyle $b 'Divider'
    $b.Padding = [System.Windows.Thickness]::new(0, 10, 0, 10)
    $d = [System.Windows.Controls.DockPanel]::new()
    $d.LastChildFill = $true
    for ($i = 0; $i -lt $Parts.Count; $i++) {
        $p = $Parts[$i]
        if ($null -eq $p) { continue }
        if ($i -lt $Parts.Count - 1) {
            [System.Windows.Controls.DockPanel]::SetDock($p, 'Left')
            $p.Margin = [System.Windows.Thickness]::new(0, 0, $Gap, 0)
        }
        $p.VerticalAlignment = 'Center'
        [void]$d.Children.Add($p)
    }
    $b.Child = $d
    $b
}

$script:ko = [System.Globalization.CultureInfo]::GetCultureInfo('ko-KR')

# 날짜를 한국어로. 예: Format-WtDate (Get-Date) 'M월 d일 dddd' → 10월 22일 목요일
function Format-WtDate([datetime]$Date, [string]$Format) { $Date.ToString($Format, $script:ko) }

function Show-WtMessage([string]$Text, [string]$Title = 'WorkTool', [string]$Icon = 'Information') {
    [void][System.Windows.MessageBox]::Show($Text, $Title, 'OK', $Icon)
}

function Confirm-WtYesNo([string]$Text, [string]$Title = 'WorkTool') {
    [System.Windows.MessageBox]::Show($Text, $Title, 'YesNo', 'Question') -eq 'Yes'
}

# 오류를 사용자에게 보여 준다. 문구는 그대로 복사해서 알려 줄 수 있게 한다.
function Show-WtError($ErrorRecord, [string]$Where = '') {
    $msg = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $pos = if ($ErrorRecord.InvocationInfo) { $ErrorRecord.InvocationInfo.PositionMessage } else { '' }
        "$($ErrorRecord.Exception.Message)`n`n위치: $pos"
    } elseif ($ErrorRecord -is [System.Exception]) {
        "$($ErrorRecord.Message)`n`n$($ErrorRecord.StackTrace)"
    } else { [string]$ErrorRecord }
    if ($Where) { $msg = "[$Where]`n$msg" }
    try { Show-WtMessage $msg 'WorkTool 오류' 'Error' } catch { Write-Host $msg }
}

function New-WtTaskGrid {
    $grid = ConvertFrom-WtXaml @'
<DataGrid {NS} AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" CanUserDeleteRows="False"
  HeadersVisibility="Column" SelectionMode="Single" SelectionUnit="FullRow" BorderThickness="0" IsSynchronizedWithCurrentItem="False"
  Background="{DynamicResource B.Bg.Surface}" Foreground="{DynamicResource B.Text.Primary}"
  FontFamily="{DynamicResource Font.UI}" FontSize="{DynamicResource F.Body}"
  RowStyle="{DynamicResource Task.Row}" CellStyle="{DynamicResource Task.Cell}" ColumnHeaderStyle="{DynamicResource Task.Header}"
  GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="{DynamicResource B.Border.Muted}"
  RowHeight="{DynamicResource F.Height.Control}" ColumnHeaderHeight="{DynamicResource F.Height.Control}"
  EnableRowVirtualization="True" EnableColumnVirtualization="True"
  VirtualizingPanel.IsVirtualizingWhenGrouping="True" VirtualizingPanel.VirtualizationMode="Recycling" ScrollViewer.CanContentScroll="True">
  <DataGrid.Columns>
    <DataGridTemplateColumn Header="" Width="60" CanUserSort="False">
      <DataGridTemplateColumn.CellTemplate><DataTemplate>
        <CheckBox Tag="task" Style="{DynamicResource Task.Check}" IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
          IsEnabled="{Binding CanClose}" ToolTip="{Binding CloseHint}" AutomationProperties.Name="{Binding DisplayTitle}"/>
      </DataTemplate></DataGridTemplateColumn.CellTemplate>
    </DataGridTemplateColumn>
    <DataGridTextColumn Header="이름" Binding="{Binding DisplayTitle}" SortMemberPath="DisplayTitle" Width="*" MinWidth="200" />
    <DataGridTextColumn Header="종류" Binding="{Binding KindLabel}" SortMemberPath="KindLabel" Width="72" />
    <DataGridTextColumn Header="창" Binding="{Binding WindowLabel}" SortMemberPath="WindowNumber" Width="72" />
    <DataGridTextColumn Header="상태" Binding="{Binding Status}" SortMemberPath="Status" Width="200" />
  </DataGrid.Columns>
  <DataGrid.GroupStyle><GroupStyle>
    <GroupStyle.ContainerStyle><Style TargetType="GroupItem"><Setter Property="Template"><Setter.Value>
      <ControlTemplate TargetType="GroupItem">
        <Expander Tag="task-group" IsExpanded="True" Style="{DynamicResource Task.Group}">
          <Expander.Header><StackPanel Orientation="Horizontal">
            <CheckBox Tag="group" IsThreeState="True" Style="{DynamicResource Task.GroupCheck}" AutomationProperties.Name="{Binding Name}"/>
            <TextBlock Text="{Binding Name}" Style="{DynamicResource T.Strong}" Margin="12,0,0,0" VerticalAlignment="Center"/>
            <TextBlock Text="{Binding ItemCount}" Style="{DynamicResource T.CaptionMuted}" Margin="8,0,0,0" VerticalAlignment="Center"/>
          </StackPanel></Expander.Header>
          <ItemsPresenter/>
        </Expander>
      </ControlTemplate>
    </Setter.Value></Setter></Style></GroupStyle.ContainerStyle>
  </GroupStyle></DataGrid.GroupStyle>
</DataGrid>
'@
    # 열은 시각 트리 밖이라 DynamicResource가 듣지 않는다. 스타일 안의 색은 자원 이름으로 남아 테마를 따른다.
    $styles = Get-WtStyleDictionary
    $grid.Columns[0].CellStyle = $styles['Task.CheckCell']
    foreach ($column in @($grid.Columns)[1..4]) { $column.ElementStyle = $styles['Task.Text'] }
    # 그룹 행의 ItemsPresenter가 무한 폭으로 측정돼도 이름 열이 남는 폭을 채운다.
    $grid.Add_SizeChanged({ param($s, $e) $s.Columns[1].Width = [System.Windows.Controls.DataGridLength]::new([Math]::Max(200, $s.ActualWidth - 60 - 72 - 72 - 200 - 24)) })
    $grid
}

# 카드 한 장을 채우는 화면. 머리줄 · 표 · 아래 줄의 여백은 Card.Head · Card.Body · Card.Foot으로 준다
function New-WtTaskPage {
    $page = New-WtPage -Fill
    $card = New-WtCard
    Set-WtStyle $card 'Panel.Surface'
    $inner = [System.Windows.Controls.DockPanel]::new()
    $card.Child = $inner
    [void]$page.Panel.Children.Add($card)
    @{ Root = $page.Root; Panel = $inner }
}

# 대화상자 모양은 여기에서만 정한다. 호출자는 본문/버튼과 처리기만 붙인다.
function New-WtModal([string]$Title) {
    $w = [System.Windows.Window]::new()
    $w.Title = $Title; $w.Width = 480; $w.SizeToContent = 'Height'; $w.ResizeMode = 'NoResize'
    $w.WindowStyle = 'ToolWindow'; $w.ShowInTaskbar = $false; $w.WindowStartupLocation = 'CenterOwner'
    $owner = Get-WtWindow
    if ($owner -and $owner.IsVisible) { $w.Owner = $owner; $w.Resources.MergedDictionaries.Add($owner.Resources) }
    else { $w.Resources.MergedDictionaries.Add((New-WtThemeDictionary)); $w.Resources.MergedDictionaries.Add((Get-WtStyleDictionary)) }
    Set-WtResource $w Background 'B.Card'; Set-WtResource $w Foreground 'B.Text'; Set-WtResource $w FontFamily 'Font.UI'
    $body = New-WtStack Vertical 12; $body.Margin = [System.Windows.Thickness]::new(24)
    $heading = New-WtText $Title 'T.Dialog'
    [void](Add-WtChild $body $heading)
    $content = New-WtStack Vertical 8; [void](Add-WtChild $body $content)
    $errorText = New-WtText '' 'T.Sub'; Set-WtResource $errorText Foreground 'B.Danger'
    $errorText.Visibility = 'Collapsed'; [void](Add-WtChild $body $errorText)
    $buttons = New-WtStack Horizontal 8; $buttons.HorizontalAlignment = 'Right'
    $buttons.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0); [void](Add-WtChild $body $buttons)
    $w.Content = $body
    @{ Window = $w; Body = $content; Error = $errorText; Buttons = $buttons }
}

function New-WtMinuteInput([int]$Value) {
    $row = New-WtStack Horizontal 12
    $box = [System.Windows.Controls.TextBox]::new(); Set-WtStyle $box 'Input'
    $box.Width = 160; $box.Text = [string]$Value
    [System.Windows.Automation.AutomationProperties]::SetName($box, '새로 고침 간격 (분)')
    [void](Add-WtChild $row $box)
    $unit = New-WtText '분'; $unit.VerticalAlignment = 'Center'; [void](Add-WtChild $row $unit)
    @{ Root = $row; Box = $box }
}

function New-WtPollTimer([scriptblock]$Tick) {
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick($Tick)
    $timer
}

function Get-WtUiWorkBudget { @{ Milliseconds = 16; Items = 32 } }

# PageUp → -1, PageDown → 1, 나머지 → 0. 키 이름 글자로 비교하지 않는다:
# WPF에서 PageDown은 Next와 같은 값이라 글자로 바꾸면 'Next'가 나와 'PageDown'과 맞지 않는다(PageUp도 Prior와 같은 값)
function Get-WtPageStep($Key) {
    if ($Key -eq [System.Windows.Input.Key]::PageUp) { return -1 }
    if ($Key -eq [System.Windows.Input.Key]::PageDown) { return 1 }
    0
}

# 해 · 달 고르기. $Popup은 화면 XAML 안에 둔 Popup이다(그래야 창의 테마 자원을 물려받는다).
# OnPick { param([datetime]$Month) }는 고른 달의 1일을 받는다. 보고 있는 달은 강조색이다.
# 키: Esc 닫기, PageUp · PageDown 해 이동, Tab · 화살표로 달 칸 이동, Enter · Space 고르기
function New-WtMonthPicker($Popup, [scriptblock]$OnPick, [scriptblock]$OnToday) {
    $picker = @{ Popup = $Popup; OnPick = $OnPick; OnToday = $OnToday; Year = [datetime]::Today.Year; Current = [datetime]::Today; Buttons = [System.Collections.Generic.List[object]]::new(); YearText = $null }
    $panel = [System.Windows.Controls.Border]::new(); Set-WtStyle $panel 'Picker.Panel'; $panel.Tag = $picker
    $col = New-WtStack
    $head = [System.Windows.Controls.DockPanel]::new(); Set-WtStyle $head 'Picker.Head'
    foreach ($step in -1, 1) {
        $tip = if ($step -lt 0) { '이전 해 (PageUp)' } else { '다음 해 (PageDown)' }
        $b = New-WtButton '' -Kind Icon -Icon $(if ($step -lt 0) { 0xE76B } else { 0xE76C }) -ToolTip $tip
        [System.Windows.Automation.AutomationProperties]::SetName($b, $tip)
        $b.Tag = @{ Picker = $picker; Step = $step }
        $b.Add_Click({ param($s, $e) $s.Tag.Picker.Year += $s.Tag.Step; Update-WtMonthPicker $s.Tag.Picker })
        [System.Windows.Controls.DockPanel]::SetDock($b, $(if ($step -lt 0) { 'Left' } else { 'Right' }))
        [void]$head.Children.Add($b)
    }
    $picker.YearText = New-WtText '' 'Picker.Year'; [void]$head.Children.Add($picker.YearText)
    $grid = [System.Windows.Controls.Primitives.UniformGrid]::new(); $grid.Columns = 4
    for ($m = 1; $m -le 12; $m++) {
        $b = [System.Windows.Controls.Button]::new(); $b.Content = "${m}월"; $b.Tag = @{ Picker = $picker; Month = $m }
        $b.Add_Click({ param($s, $e) $p = $s.Tag.Picker; $p.Popup.IsOpen = $false; & $p.OnPick ([datetime]::new($p.Year, $s.Tag.Month, 1)) })
        [void]$grid.Children.Add($b); $picker.Buttons.Add($b)
    }
    [void]$col.Children.Add($head); [void]$col.Children.Add($grid)
    # 「오늘」: 이번 달 · 오늘로 간다(OnToday를 줬을 때만)
    if ($OnToday) {
        $today = New-WtButton '오늘' -Kind Link -ToolTip '오늘로 가기'; Set-WtStyle $today 'Picker.Today'; $today.Tag = $picker
        $today.Add_Click({ param($s, $e) $p = $s.Tag; $p.Popup.IsOpen = $false; & $p.OnToday })
        [void]$col.Children.Add($today); $picker.Today = $today
    }
    $panel.Child = $col
    $panel.Add_PreviewKeyDown({ param($s, $e) if (Invoke-WtMonthPickerKey $s.Tag $e.Key) { $e.Handled = $true } })
    $Popup.Child = $panel
    $picker
}
# 고르기 창의 키: Esc 닫기, PageUp · PageDown 해 이동. 처리했으면 $true
function Invoke-WtMonthPickerKey($Picker, $Key) {
    if ($Key -eq [System.Windows.Input.Key]::Escape) { $Picker.Popup.IsOpen = $false; return $true }
    $step = Get-WtPageStep $Key
    if (-not $step) { return $false }
    $Picker.Year += $step; Update-WtMonthPicker $Picker
    $true
}
function Update-WtMonthPicker($Picker) {
    $Picker.YearText.Text = "$($Picker.Year)년"
    for ($i = 0; $i -lt 12; $i++) {
        $b = $Picker.Buttons[$i]
        $selected = $Picker.Year -eq $Picker.Current.Year -and ($i + 1) -eq $Picker.Current.Month
        Set-WtStyle $b $(if ($selected) { 'Picker.MonthSelected' } else { 'Picker.Month' })
        [System.Windows.Automation.AutomationProperties]::SetName($b, "$($Picker.Year)년 $($i + 1)월")
    }
}
# 보고 있는 달($Current)로 맞춰 연다. 그 달 칸에 포커스를 둔다
function Open-WtMonthPicker($Picker, [datetime]$Current) {
    $Picker.Current = $Current; $Picker.Year = $Current.Year
    Update-WtMonthPicker $Picker
    $Picker.Popup.IsOpen = $true
    $target = $Picker.Buttons[$Current.Month - 1]
    [void]$target.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input, [Action]({ [void]$target.Focus() }.GetNewClosure()))
}

function New-WtContextMenu {
    $menu = [System.Windows.Controls.ContextMenu]::new()
    Set-WtResource $menu Background 'B.Card'; Set-WtResource $menu Foreground 'B.Text'
    Set-WtResource $menu FontFamily 'Font.UI'; Set-WtResource $menu FontSize 'F.Body'
    $menu
}

function Get-WtVisualChild($Root, [type]$Type) {
    if ($Root -is $Type) { return $Root }
    for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Root); $i++) {
        $found = Get-WtVisualChild ([System.Windows.Media.VisualTreeHelper]::GetChild($Root, $i)) $Type
        if ($found) { return $found }
    }
    $null
}

Export-ModuleMember -Function New-WtMonthPicker, Update-WtMonthPicker, Open-WtMonthPicker, Invoke-WtMonthPickerKey, Get-WtPageStep
Export-ModuleMember -Function Get-WtUiWorkBudget, New-WtPollTimer, New-WtTaskGrid, New-WtTaskPage, New-WtModal, New-WtMinuteInput, New-WtContextMenu, Get-WtVisualChild,
    Get-WtStyleDictionary, ConvertFrom-WtXaml, Get-WtNamedElements, Set-WtStyle, Set-WtResource,
    New-WtText, New-WtIcon, New-WtStack, Add-WtChild, New-WtCard, New-WtCardHeader, New-WtButton, New-WtButtonContent, New-WtSegmented, New-WtSearchBox, New-WtTag, New-WtFilterChip,
    New-WtStatTile, New-WtPageHeader, New-WtPage, New-WtListRow, Format-WtDate, Show-WtMessage, Confirm-WtYesNo, Show-WtError

# 상태에 따른 치수·배치만 바꾼다. 저장·단축키 판단은 Shell이 한다.
function Set-WtNavLayout($Ui, $Items, $Groups, [bool]$Collapsed) {
    $styles = Get-WtStyleDictionary
    $Ui.NavBorder.Width = $styles[$(if ($Collapsed) { 'F.Nav.CollapsedWidth' } else { 'F.Nav.Width' })]
    $vis = if ($Collapsed) { 'Collapsed' } else { 'Visible' }
    foreach ($group in $Groups) { $group.Visibility = $vis }
    foreach ($item in $Items) {
        $item.Label.Visibility = $vis
        $item.Button.Padding = if ($Collapsed) { [System.Windows.Thickness]::new(8,0,8,0) } else { [System.Windows.Thickness]::new(12,0,8,0) }
        $item.Count.Visibility = if (-not $Collapsed -and $null -ne $item.Value -and $item.Value -ne 'dot') { 'Visible' } else { 'Collapsed' }
        $item.Dot.Visibility = if (-not $Collapsed -and $item.Value -eq 'dot') { 'Visible' } else { 'Collapsed' }
        $item.IconDot.Visibility = if ($Collapsed -and $item.Value -eq 'dot') { 'Visible' } else { 'Collapsed' }
    }
    $Ui.FooterPanel.Orientation = if ($Collapsed) { 'Vertical' } else { 'Horizontal' }
    $Ui.FooterPanel.Margin = if ($Collapsed) { [System.Windows.Thickness]::new(8,8,0,12) } else { [System.Windows.Thickness]::new(12,8,0,12) }
    $Ui.HelpButton.Margin = if ($Collapsed) { [System.Windows.Thickness]::new(0,0,0,4) } else { [System.Windows.Thickness]::new(0,0,8,0) }
    $Ui.CollapseButton.Margin = if ($Collapsed) { [System.Windows.Thickness]::new(10,0,0,0) } else { [System.Windows.Thickness]::new(12,0,0,0) }
}

function Set-WtSidePanelLayout($Panel, [bool]$Collapsed, [bool]$Narrow) {
    $railWidth = (Get-WtStyleDictionary)['F.SidePanel.RailWidth']
    $Panel.Root.Width = if ($Collapsed -or $Narrow) { $railWidth } else { $Panel.Width }
    $Panel.Root.HorizontalAlignment = $Panel.Side
    $Panel.Expanded.Width = $Panel.Width
    $Panel.Expanded.HorizontalAlignment = $Panel.Side
    $Panel.Rail.HorizontalAlignment = $Panel.Side
    $Panel.Expanded.Visibility = if ($Collapsed) { 'Collapsed' } else { 'Visible' }
    $Panel.Rail.Visibility = if ($Collapsed) { 'Visible' } else { 'Collapsed' }
    # 카드 사이는 간격으로 나눈다. 내용 위에 겹칠 때만 선으로 경계를 보인다.
    $gap = (Get-WtStyleDictionary)['F.SidePanel.Gap']
    $Panel.Root.Margin = if ($Panel.Side -eq 'Right') { [System.Windows.Thickness]::new($gap, 0, 0, 0) } else { [System.Windows.Thickness]::new(0, 0, $gap, 0) }
    $Panel.Expanded.BorderThickness = [System.Windows.Thickness]::new($(if ($Narrow -and -not $Collapsed) { 1 } else { 0 }))
    [System.Windows.Controls.DockPanel]::SetDock($Panel.Collapse, $(if ($Panel.Side -eq 'Right') { 'Left' } else { 'Right' }))
    $Panel.CollapseGlyph.Text = [string][char]$(if ($Panel.Side -eq 'Right') { 0xE76C } else { 0xE76B })
    $Panel.OpenGlyph.Text = [string][char]$(if ($Panel.Side -eq 'Right') { 0xE76B } else { 0xE76C })
}

Export-ModuleMember -Function Get-WtShellXaml, Set-WtNavLayout, Set-WtSidePanelLayout

# 홈 전용 배치 · 공통 부품. 값은 디자인 3판 7·8절.
# 내용이 창보다 작으면 마지막 카드가 남은 높이를 채우고, 크면 화면 전체가 스크롤된다.
function New-WtHomeLayout {
    $scroll = [System.Windows.Controls.ScrollViewer]::new()
    $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'; $scroll.Focusable = $false
    $root = [System.Windows.Controls.DockPanel]::new()
    $viewport = [System.Windows.Data.Binding]::new('ViewportHeight'); $viewport.Source = $scroll
    [void]$root.SetBinding([System.Windows.FrameworkElement]::MinHeightProperty, $viewport)
    $headArea = New-WtStack Vertical; Set-WtStyle $headArea 'Home.Head'
    $title = New-WtText '' 'T.Display'; [void]$headArea.Children.Add($title)
    $head = New-WtStack Vertical; [void]$headArea.Children.Add($head)
    [System.Windows.Controls.DockPanel]::SetDock($headArea, 'Top'); [void]$root.Children.Add($headArea)
    $grid = [System.Windows.Controls.Grid]::new()
    foreach ($width in @([System.Windows.GridLength]::new(1, 'Star'), [System.Windows.GridLength]::new(8), [System.Windows.GridLength]::new(320))) {
        $column = [System.Windows.Controls.ColumnDefinition]::new(); $column.Width = $width; $grid.ColumnDefinitions.Add($column)
    }
    $main = [System.Windows.Controls.DockPanel]::new(); $main.Tag = [double]8
    $side = [System.Windows.Controls.DockPanel]::new(); $side.Tag = [double]8
    [System.Windows.Controls.Grid]::SetColumn($side, 2)
    [void]$grid.Children.Add($main); [void]$grid.Children.Add($side); [void]$root.Children.Add($grid)
    $scroll.Content = $root
    @{ Root = $scroll; Title = $title; Head = $head; Main = $main; Side = $side }
}

function New-WtHomePinMenuItem($Shortcut, [scriptblock]$OnChange) {
    $menuItem = [System.Windows.Controls.MenuItem]::new()
    $menuItem.Header = if (Test-WtHomePin -Page $Shortcut.Page -Key $Shortcut.Key) { '홈 고정 해제' } else { '홈에 고정' }
    $menuItem.Tag = @{ Shortcut = $Shortcut; OnChange = $OnChange }
    $menuItem.Add_Click({
            param($s, $e)
            $target = $s.Tag.Shortcut
            Set-WtHomePin -Page $target.Page -Key $target.Key -Title $target.Title -Sub $target.Sub -Icon $target.Icon -Pinned:(-not (Test-WtHomePin -Page $target.Page -Key $target.Key))
            if ($s.Tag.OnChange) { & $s.Tag.OnChange }
        })
    $menuItem
}

function New-WtShortcutTile($Shortcut, [scriptblock]$OnChange) {
    $button = [System.Windows.Controls.Button]::new(); Set-WtStyle $button 'Home.Tile'
    $button.Tag = $Shortcut; $button.ToolTip = $Shortcut.Title
    [System.Windows.Automation.AutomationProperties]::SetName($button, $Shortcut.Title)
    $row = [System.Windows.Controls.DockPanel]::new()
    $icon = New-WtIcon ([int]$Shortcut.Icon); $icon.Width = 16; $icon.Height = 16; $icon.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
    Set-WtResource $icon Foreground 'B.Text.Secondary'
    [System.Windows.Controls.DockPanel]::SetDock($icon, 'Left'); [void]$row.Children.Add($icon)
    $texts = New-WtStack Vertical; $texts.VerticalAlignment = 'Center'
    $titleText = New-WtText $Shortcut.Title; $titleText.TextWrapping = 'NoWrap'; $titleText.TextTrimming = 'CharacterEllipsis'
    $subText = New-WtText $Shortcut.Sub 'T.CaptionMuted'; $subText.TextWrapping = 'NoWrap'; $subText.TextTrimming = 'CharacterEllipsis'
    [void]$texts.Children.Add($titleText); [void]$texts.Children.Add($subText); [void]$row.Children.Add($texts)
    $button.Content = $row
    $button.Add_Click({ param($s, $e) Open-WtPage -Id $s.Tag.Page -Args @{ Key = $s.Tag.Key } })
    $button.ContextMenu = New-WtHomePinContextMenu
    $button.ContextMenu.Tag = $OnChange
    [void]$button.ContextMenu.Items.Add((New-WtHomePinMenuItem $Shortcut -OnChange $OnChange))
    $button.Add_ContextMenuOpening({
            param($s, $e)
            $s.ContextMenu.Items.Clear()
            [void]$s.ContextMenu.Items.Add((New-WtHomePinMenuItem $s.Tag -OnChange $s.ContextMenu.Tag))
        })
    $button
}

function New-WtShortcutCard([object[]]$Items, [scriptblock]$OnChange) {
    $card = New-WtCard; Set-WtStyle $card 'Home.Card'
    $panel = New-WtStack Vertical 4
    [void](Add-WtChild $panel (New-WtText '바로 가기' 'T.H2'))
    $card.Child = $panel
    if (-not $Items.Count) { [void](Add-WtChild $panel (New-WtText '자주 연 항목이 여기에 표시됩니다' 'T.Sub')); return $card }
    $grid = [System.Windows.Controls.Grid]::new()
    foreach ($width in @([System.Windows.GridLength]::new(1, 'Star'), [System.Windows.GridLength]::new(32), [System.Windows.GridLength]::new(1, 'Star'))) {
        $cd = [System.Windows.Controls.ColumnDefinition]::new(); $cd.Width = $width; $grid.ColumnDefinitions.Add($cd)
    }
    for ($i = 0; $i -lt [Math]::Min(8, $Items.Count); $i++) {
        $rowIndex = [int][Math]::Floor($i / 2)
        if ($i % 2 -eq 0) { $rd = [System.Windows.Controls.RowDefinition]::new(); $rd.Height = [System.Windows.GridLength]::Auto; $grid.RowDefinitions.Add($rd) }
        $tile = New-WtShortcutTile $Items[$i] -OnChange $OnChange
        [System.Windows.Controls.Grid]::SetColumn($tile, ($i % 2) * 2); [System.Windows.Controls.Grid]::SetRow($tile, $rowIndex)
        [void]$grid.Children.Add($tile)
    }
    [void](Add-WtChild $panel $grid)
    $card
}

# 콜백은 달 이동만 맡는다. 날짜 이동은 코어의 CalendarHost 등록을 거친다.
function New-WtMiniCalendar([datetime]$Month, $Calendar, [scriptblock]$OnMonth) {
    $card = New-WtCard; Set-WtStyle $card 'Home.Card'
    $card.Tag = @{ Month = $Month; OnMonth = $OnMonth }
    $col = New-WtStack Vertical
    $header = [System.Windows.Controls.Grid]::new(); $header.Height = 28; $header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    $monthText = New-WtText (Format-WtDate $Month 'yyyy년 M월') 'T.H2'; $monthText.VerticalAlignment = 'Center'
    [void]$header.Children.Add($monthText)
    $nav = New-WtStack Horizontal 4; $nav.HorizontalAlignment = 'Right'
    foreach ($step in -1, 1) {
        $button = New-WtButton '' -Kind Icon -Icon $(if ($step -lt 0) { 0xE76B } else { 0xE76C }) -ToolTip $(if ($step -lt 0) { '이전 달' } else { '다음 달' })
        [System.Windows.Automation.AutomationProperties]::SetName($button, [string]$button.ToolTip)
        $button.Tag = @{ Step = $step; Month = $Month; OnMonth = $OnMonth }
        $button.Add_Click({ param($s, $e) & $s.Tag.OnMonth ($s.Tag.Month.AddMonths($s.Tag.Step)) })
        [void](Add-WtChild $nav $button)
    }
    [void]$header.Children.Add($nav); [void](Add-WtChild $col $header)
    $week = [System.Windows.Controls.Primitives.UniformGrid]::new(); $week.Columns = 7; $week.Height = 20
    foreach ($name in '일', '월', '화', '수', '목', '금', '토') {
        $text = New-WtText $name 'T.CaptionMuted'; $text.TextAlignment = 'Center'; [void]$week.Children.Add($text)
    }
    [void](Add-WtChild $col $week)
    $days = [System.Windows.Controls.Primitives.UniformGrid]::new(); $days.Columns = 7; $days.Rows = 6
    $first = [datetime]::new($Month.Year, $Month.Month, 1); $start = $first.AddDays(-[int]$first.DayOfWeek)
    $hostAddon = Get-WtCalendarHost
    for ($i = 0; $i -lt 42; $i++) {
        $date = $start.AddDays($i); $mark = Get-WtCalendarMark $date $Calendar.Items
        $isToday = $date -eq [datetime]::Today; $inMonth = $date.Month -eq $Month.Month
        $weekend = $date.DayOfWeek -in [DayOfWeek]::Sunday, [DayOfWeek]::Saturday
        $button = [System.Windows.Controls.Button]::new(); Set-WtStyle $button 'Home.CalendarDay'
        $button.Tag = @{ Page = $(if ($hostAddon) { $hostAddon.Id } else { '' }); Date = $date }
        [System.Windows.Automation.AutomationProperties]::SetName($button, (ConvertTo-WtDateText $date))
        $button.IsEnabled = $null -ne $hostAddon
        $button.ToolTip = if ($Calendar.Errors.Count) { @($Calendar.Errors.Reason) -join "`n" } elseif ($mark.ToolTip) { $mark.ToolTip } else { Format-WtDate $date 'M월 d일 dddd' }
        $dateCircle = [System.Windows.Controls.Border]::new(); $dateCircle.Width = 22; $dateCircle.Height = 22; $dateCircle.CornerRadius = 11
        $number = New-WtText ([string]$date.Day) 'T.Sub'; $number.TextAlignment = 'Center'; $number.VerticalAlignment = 'Center'
        $painted = $inMonth -and $mark.Kind
        Set-WtResource $number Foreground $(if ($isToday) { 'B.OnAccent' } elseif (-not $inMonth) { 'B.Text.Disabled' } elseif ($painted) { $mark.Fore } elseif ($weekend) { 'B.Text.Tertiary' } else { 'B.Text.Primary' })
        if ($isToday) { Set-WtResource $dateCircle Background 'B.Accent'; $number.FontWeight = 'SemiBold' }
        elseif ($painted) { Set-WtResource $dateCircle Background $mark.Back }
        $dateCircle.Child = $number
        $button.Content = $dateCircle
        $button.Add_Click({ param($s, $e) if ($s.Tag.Page) { Open-WtPage -Id $s.Tag.Page -Args @{ Date = $s.Tag.Date } } })
        [void]$days.Children.Add($button)
    }
    [void](Add-WtChild $col $days)
    $legend = New-WtStack Horizontal 16; $legend.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    foreach ($entry in @(@('업무외', 'B.Cal.Overtime.Bg'), @('휴가', 'B.Cal.Leave.Bg'), @('휴무일', 'B.Status.Error.Bg'))) {
        $item = New-WtStack Horizontal 6
        $swatch = [System.Windows.Controls.Border]::new(); $swatch.Width = 12; $swatch.Height = 12; $swatch.CornerRadius = 6
        Set-WtResource $swatch Background $entry[1]
        [void](Add-WtChild $item $swatch); [void](Add-WtChild $item (New-WtText $entry[0] 'T.Sub'))
        [void](Add-WtChild $legend $item)
    }
    [void](Add-WtChild $col $legend); $card.Child = $col; $card
}

# 시간 막대. 폭은 카드에 맞추므로 일정은 분으로 들고, 자리는 Set-WtTimelineLayout이 계산한다.
function New-WtTimeline([object[]]$Items, [datetime]$Date, [string]$Page, [string]$ErrorText = '') {
    $card = New-WtCard; Set-WtStyle $card 'Home.Card'
    $col = New-WtStack Vertical
    $header = New-WtCardHeader '오늘 일정' ([string]$Items.Count) '일정 열기' $Page
    $header.Margin = [System.Windows.Thickness]::new(0)
    [void](Add-WtChild $col $header)
    $allDay = @($Items | Where-Object AllDay)
    if ($allDay.Count) {
        $row = New-WtStack Horizontal 8
        $label = New-WtText '하루 종일' 'T.Sub'; $label.VerticalAlignment = 'Center'; [void](Add-WtChild $row $label)
        foreach ($entry in $allDay) {
            $button = New-WtButton $entry.Title -Kind Link
            $button.MinHeight = 20; $button.Tag = @{ Page = $Page; Date = $Date; Id = $entry.Id }; $button.ToolTip = $entry.ToolTip
            $button.Add_Click({ param($s, $e) Open-WtPage -Id $s.Tag.Page -Args @{ Date = $s.Tag.Date; Id = $s.Tag.Id } })
            [void](Add-WtChild $row $button)
        }
        [void](Add-WtChild $col $row)
    }
    $canvas = [System.Windows.Controls.Canvas]::new(); $canvas.Height = 116; $canvas.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    # 그날 적용되는 업무시간 규칙(설계 15.1)
    $workHours = Get-WtWorkHours -Date $Date
    $workStart = (ConvertFrom-WtTimeText $workHours['work.start']).TotalMinutes
    $workEnd = (ConvertFrom-WtTimeText $workHours['work.end']).TotalMinutes
    $rangeStart = $workStart - 60; $rangeEnd = $workEnd + 120
    $rail = [System.Windows.Controls.Border]::new(); $rail.Height = 20; $rail.CornerRadius = 2
    Set-WtResource $rail Background 'B.Bg.Subtle'
    [System.Windows.Controls.Canvas]::SetTop($rail, 44); [void]$canvas.Children.Add($rail)
    $work = [System.Windows.Controls.Border]::new(); $work.Height = 20
    Set-WtResource $work Background 'B.Cal.Work'
    [System.Windows.Controls.Canvas]::SetTop($work, 44); [void]$canvas.Children.Add($work)
    $ticks = [System.Collections.Generic.List[object]]::new()
    $minutes = @($rangeStart) + @(for ($minute = [Math]::Ceiling(($rangeStart + 1) / 120) * 120; $minute -lt $rangeEnd; $minute += 120) { $minute }) + @($rangeEnd)
    foreach ($minute in $minutes) {
        $text = New-WtText ($Date.AddMinutes($minute).ToString('HH', [Globalization.CultureInfo]::InvariantCulture)) 'T.CaptionMuted'
        $text.Width = 24; $text.TextAlignment = if ($minute -eq $rangeStart) { 'Left' } elseif ($minute -eq $rangeEnd) { 'Right' } else { 'Center' }
        [System.Windows.Controls.Canvas]::SetTop($text, 24); [void]$canvas.Children.Add($text)
        $ticks.Add(@{ Text = $text; Minute = $minute })
    }
    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($Items | Where-Object { -not $_.AllDay } | Sort-Object Start, End, Title)) {
        $a = ($entry.Start - $Date.Date).TotalMinutes; $b = if ($entry.End -gt $entry.Start) { ($entry.End - $Date.Date).TotalMinutes } else { $a }
        $button = [System.Windows.Controls.Button]::new(); Set-WtStyle $button 'Home.TimelineEvent'
        $button.Tag = @{ Page = $Page; Date = $Date; Id = $entry.Id }; $button.ToolTip = $entry.ToolTip
        [System.Windows.Automation.AutomationProperties]::SetName($button, $entry.Title)
        $button.Add_Click({ param($s, $e) Open-WtPage -Id $s.Tag.Page -Args @{ Date = $s.Tag.Date; Id = $s.Tag.Id } })
        if ($a -lt $rangeStart -or $b -gt $rangeEnd) {
            $markers = [System.Windows.Controls.Grid]::new(); $markers.Width = 10
            foreach ($side in 'Left', 'Right') {
                if (($side -eq 'Left' -and $a -ge $rangeStart) -or ($side -eq 'Right' -and $b -le $rangeEnd)) { continue }
                $marker = New-WtIcon $(if ($side -eq 'Left') { 0xE76B } else { 0xE76C }); $marker.FontSize = 12
                Set-WtResource $marker Foreground 'B.OnAccent'; $marker.HorizontalAlignment = $side
                [void]$markers.Children.Add($marker)
            }
            $button.Content = $markers
        }
        [void]$canvas.Children.Add($button)
        $caption = New-WtText ($entry.Start.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture) + ' ' + $entry.Title) 'T.Sub'
        $caption.TextWrapping = 'NoWrap'; $caption.IsHitTestVisible = $false; [void]$canvas.Children.Add($caption)
        $alarm = $null
        if ($entry.Alarm) {
            $alarm = New-WtIcon 0xEA8F; $alarm.FontSize = 12; Set-WtResource $alarm Foreground 'B.Accent'; $alarm.ToolTip = $entry.ToolTip
            [void]$canvas.Children.Add($alarm)
        }
        $events.Add(@{ Entry = $entry; Start = $a; End = $b; Button = $button; Caption = $caption; Alarm = $alarm })
    }
    $more = New-WtText '' 'T.Sub'; $more.Visibility = 'Collapsed'
    [System.Windows.Controls.Canvas]::SetRight($more, 0); [System.Windows.Controls.Canvas]::SetTop($more, 70); [void]$canvas.Children.Add($more)
    $nowLine = [System.Windows.Controls.Border]::new(); $nowLine.Width = 2; $nowLine.Height = 28; $nowLine.IsHitTestVisible = $false
    Set-WtResource $nowLine Background 'B.Text.Primary'; [System.Windows.Controls.Canvas]::SetTop($nowLine, 40); [void]$canvas.Children.Add($nowLine)
    $nowLabel = New-WtText '' 'T.Sub'; Set-WtResource $nowLabel Foreground 'B.Text.Primary'; $nowLabel.Width = 96; $nowLabel.TextAlignment = 'Center'; $nowLabel.IsHitTestVisible = $false
    [System.Windows.Controls.Canvas]::SetTop($nowLabel, 0); [void]$canvas.Children.Add($nowLabel)
    $canvas.Tag = @{ Date = $Date; Start = $rangeStart; End = $rangeEnd; WorkStart = $workStart; WorkEnd = $workEnd; Now = (Get-Date)
        Rail = $rail; Work = $work; Ticks = $ticks; Events = $events; More = $more; Line = $nowLine; Label = $nowLabel }
    $canvas.Add_SizeChanged({ param($s, $e) Set-WtTimelineLayout $s })
    Update-WtTimelineNow $canvas
    [void](Add-WtChild $col $canvas)
    if ($ErrorText) { $message = New-WtText '일정 파일을 읽지 못했습니다' 'T.Sub'; $message.ToolTip = $ErrorText; [void](Add-WtChild $col $message) }
    elseif (-not $Items.Count) { [void](Add-WtChild $col (New-WtText '오늘 일정 없음' 'T.Sub')) }
    $card.Child = $col
    @{ Card = $card; Timeline = $canvas }
}

function Set-WtTimelineLayout($Timeline) {
    $state = $Timeline.Tag
    $width = if ($Timeline.ActualWidth -gt 0) { $Timeline.ActualWidth } else { 584 }
    $span = $state.End - $state.Start
    $state.Rail.Width = $width
    $state.Work.Width = $width * ($state.WorkEnd - $state.WorkStart) / $span
    [System.Windows.Controls.Canvas]::SetLeft($state.Work, $width * ($state.WorkStart - $state.Start) / $span)
    foreach ($tick in $state.Ticks) {
        $x = $width * ($tick.Minute - $state.Start) / $span
        [System.Windows.Controls.Canvas]::SetLeft($tick.Text, [Math]::Clamp($x - 12, 0, $width - 24))
    }
    # 막대는 두 줄까지 쌓고, 넘치면 숨긴 뒤 오른쪽에 +n으로 묶는다.
    $ends = @([double]::NegativeInfinity, [double]::NegativeInfinity); $hidden = [System.Collections.Generic.List[string]]::new(); $placed = [System.Collections.Generic.List[object]]::new()
    foreach ($event in $state.Events) {
        $left = [Math]::Clamp($event.Start, $state.Start, $state.End); $right = [Math]::Clamp($event.End, $state.Start, $state.End)
        $barWidth = [Math]::Max(10, $width * ($right - $left) / $span)
        $x = [Math]::Min($width - $barWidth, $width * ($left - $state.Start) / $span)
        $lane = if ($x -ge $ends[0]) { 0 } elseif ($x -ge $ends[1]) { 1 } else { -1 }
        if ($lane -lt 0) {
            $event.Button.Visibility = 'Collapsed'; $event.Caption.Visibility = 'Collapsed'
            if ($event.Alarm) { $event.Alarm.Visibility = 'Collapsed' }
            $hidden.Add($event.Entry.ToolTip); continue
        }
        $ends[$lane] = $x + $barWidth
        $event.Button.Visibility = 'Visible'; if ($event.Alarm) { $event.Alarm.Visibility = 'Visible' }
        $placed.Add(@{ Event = $event; X = $x; Width = $barWidth; Lane = $lane })
    }
    $stacked = @($placed | Where-Object { $_.Lane -eq 1 }).Count -gt 0
    $captionEnds = @([double]::NegativeInfinity, [double]::NegativeInfinity)
    $infinite = [System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity)
    foreach ($item in $placed) {
        $event = $item.Event; $button = $event.Button
        $button.Width = $item.Width; $button.Height = if ($stacked) { 8 } else { 14 }
        if ($button.Content) { $button.Content.Width = $item.Width }  # 범위 밖 표시를 양 끝에 맞춘다.
        $top = if ($stacked) { 46 + $item.Lane * 8 } else { 47 }
        [System.Windows.Controls.Canvas]::SetLeft($button, $item.X); [System.Windows.Controls.Canvas]::SetTop($button, $top)
        if ($event.Alarm) { [System.Windows.Controls.Canvas]::SetLeft($event.Alarm, $item.X + $item.Width); [System.Windows.Controls.Canvas]::SetTop($event.Alarm, $top - 2) }
        $event.Caption.Measure($infinite); $captionWidth = $event.Caption.DesiredSize.Width
        $captionX = [Math]::Max(0, [Math]::Min($item.X, $width - $captionWidth))
        $line = if ($captionX -ge $captionEnds[0]) { 0 } elseif ($captionX -ge $captionEnds[1]) { 1 } else { -1 }
        $event.Caption.Visibility = if ($line -lt 0) { 'Collapsed' } else { 'Visible' }
        if ($line -ge 0) {
            $captionEnds[$line] = $captionX + $captionWidth + 8
            [System.Windows.Controls.Canvas]::SetLeft($event.Caption, $captionX); [System.Windows.Controls.Canvas]::SetTop($event.Caption, 70 + $line * 18)
        }
    }
    $state.More.Visibility = if ($hidden.Count) { 'Visible' } else { 'Collapsed' }
    $state.More.Text = "+$($hidden.Count)"; $state.More.ToolTip = $hidden -join "`n`n"
    $minute = ($state.Now - $state.Date.Date).TotalMinutes
    $visible = $minute -ge $state.Start -and $minute -le $state.End
    $state.Line.Visibility = $state.Label.Visibility = if ($visible) { 'Visible' } else { 'Collapsed' }
    if ($visible) {
        $x = $width * ($minute - $state.Start) / $span
        [System.Windows.Controls.Canvas]::SetLeft($state.Line, $x - 1)
        [System.Windows.Controls.Canvas]::SetLeft($state.Label, [Math]::Clamp($x - 48, 0, $width - 96))
        $state.Label.Text = '지금 ' + $state.Now.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    }
}

# 지난 일정은 흐리게, 다음 일정은 진하게, 그 뒤는 옅게 칠한다.
function Update-WtTimelineNow($Timeline, [datetime]$Now = (Get-Date)) {
    $state = $Timeline.Tag; $state.Now = $Now; $nextFound = $false
    foreach ($event in $state.Events) {
        $entry = $event.Entry
        $past = $(if ($entry.End -gt $entry.Start) { $entry.End } else { $entry.Start }) -le $Now
        $look = if ($past) { 'past' } elseif (-not $nextFound) { 'next' } else { 'later' }
        if ($look -eq 'next') { $nextFound = $true }
        Set-WtResource $event.Button Background $(switch ($look) { 'past' { 'B.Border.Strong' } 'next' { 'B.Accent' } default { 'B.Accent.Later' } })
        Set-WtResource $event.Caption Foreground $(switch ($look) { 'past' { 'B.Text.Tertiary' } 'next' { 'B.Text.Primary' } default { 'B.Text.Secondary' } })
        $event.Caption.FontWeight = if ($look -eq 'next') { 'SemiBold' } else { 'Normal' }
    }
    Set-WtTimelineLayout $Timeline
}

# 홈 제목 아래 다음 일정 줄. 남은 일정이 없으면 숨긴다.
function New-WtNextEventLine([object[]]$Items) {
    $line = New-WtStack Horizontal 8; $line.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0)
    $pill = [System.Windows.Controls.Border]::new(); Set-WtStyle $pill 'Home.NextPill'
    $pill.Child = New-WtText '' 'Home.NextPillText'
    $title = New-WtText '' 'T.Strong'; $title.VerticalAlignment = 'Center'; $title.TextWrapping = 'NoWrap'; $title.TextTrimming = 'CharacterEllipsis'
    [void](Add-WtChild $line $pill); [void](Add-WtChild $line $title)
    $line.Tag = @{ Items = @($Items | Where-Object { -not $_.AllDay } | Sort-Object Start, End, Title); Pill = $pill; Title = $title }
    Update-WtNextEventLine $line
    $line
}

function Update-WtNextEventLine($Line, [datetime]$Now = (Get-Date)) {
    $state = $Line.Tag
    $next = @($state.Items | Where-Object { $(if ($_.End -gt $_.Start) { $_.End } else { $_.Start }) -gt $Now } | Select-Object -First 1)
    $Line.Visibility = if ($next.Count) { 'Visible' } else { 'Collapsed' }
    if (-not $next.Count) { return }
    $left = [int][Math]::Ceiling(($next[0].Start - $Now).TotalMinutes)
    $state.Pill.Child.Text = if ($left -le 0) { '진행 중' } elseif ($left -lt 60) { "${left}분 후" } elseif ($left % 60) { "$([Math]::Floor($left / 60))시간 $($left % 60)분 후" } else { "$($left / 60)시간 후" }
    $state.Title.Text = $next[0].Start.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture) + ' ' + $next[0].Title
}

function Set-WtTargetRowSelected($Row, [bool]$Selected) {
    $state = $null
    if (-not $script:targetRows.TryGetValue($Row, [ref]$state)) {
        $content = $Row.Child; $titleText = $content.Children[$content.Children.Count - 1]
        $Row.Child = $null
        $grid = [System.Windows.Controls.Grid]::new(); [void]$grid.Children.Add($content)
        $marker = [System.Windows.Controls.Border]::new(); $marker.Width = 3; $marker.Height = 16; $marker.CornerRadius = 1.5
        $marker.HorizontalAlignment = 'Left'; $marker.VerticalAlignment = 'Center'; $marker.IsHitTestVisible = $false
        # 기존 줄의 글자 위치를 바꾸지 않고, 막대 3 + 간격 1을 카드의 안쪽 여백에 놓는다.
        $marker.Margin = [System.Windows.Thickness]::new(-(3 + 1), 0, 0, 0)
        Set-WtResource $marker Background 'B.Accent'; [void]$grid.Children.Add($marker)
        $Row.Child = $grid
        $state = @{ Title = $titleText; Marker = $marker }; $script:targetRows.Add($Row, $state)
    }
    [System.Windows.Automation.AutomationProperties]::SetItemStatus($state.Title, $(if ($Selected) { '선택됨' } else { '' }))
    $state.Marker.Visibility = if ($Selected) { 'Visible' } else { 'Collapsed' }
    if ($Selected) { Set-WtResource $Row Background 'B.Bg.Selected' }
    else { $Row.ClearValue([System.Windows.Controls.Border]::BackgroundProperty) }
    Set-WtResource $Row BorderBrush 'B.Border.Muted'
    $Row.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 1)
}

function New-WtHomePinContextMenu {
    $menu = New-WtContextMenu
    Set-WtStyle $menu 'Home.PinMenu'
    $menu
}

Export-ModuleMember -Function New-WtHomeLayout, New-WtHomePinContextMenu, New-WtHomePinMenuItem, New-WtShortcutCard, New-WtMiniCalendar, New-WtTimeline, Set-WtTimelineLayout, New-WtNextEventLine, Update-WtNextEventLine, Update-WtTimelineNow, Set-WtTargetRowSelected

# ---- 따로 뜨는 창 (일정 2단계: 메모 새 창) -----------------------------------------------------------
# 앱 창과 같은 32 제목 줄(표식 · 제목 · 최대화 · 닫기) + 도구 줄 40 + 흰 카드 본문. 모양은 여기서만 정하고, 내용은 부르는 탭이 채운다.
# 앱 창이 떠 있으면 Owner로 붙여 함께 숨고 닫히며, 앱 창의 테마 자원을 합친다(New-WtModal과 같음).
function Get-WtSideWindowXaml {
@'
<Window {NS} Width="640" Height="560" MinWidth="400" MinHeight="300" WindowStyle="None" ResizeMode="CanResize" ShowInTaskbar="False"
    WindowStartupLocation="CenterOwner" UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Ideal"
    FontFamily="{DynamicResource Font.UI}" FontSize="{DynamicResource F.Body}" Foreground="{DynamicResource B.Text}" Background="{DynamicResource B.Bg.Canvas}">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="32" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Grid x:Name="Frame">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <DockPanel Height="{DynamicResource F.Chrome.Height}">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <Button x:Name="MaxButton" Style="{DynamicResource Btn.Chrome}" WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="최대화" AutomationProperties.Name="최대화">
          <TextBlock x:Name="MaxGlyph" Text="&#xE922;" Style="{DynamicResource T.Icon}" FontSize="10"/>
        </Button>
        <Button x:Name="CloseButton" Style="{DynamicResource Btn.Close}" WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="닫기" AutomationProperties.Name="닫기">
          <TextBlock Text="&#xE8BB;" Style="{DynamicResource T.Icon}" FontSize="10"/>
        </Button>
      </StackPanel>
      <StackPanel Orientation="Horizontal">
        <Border Style="{DynamicResource Shell.Brand}"><TextBlock Text="W" Style="{DynamicResource Shell.BrandLetter}"/></Border>
        <TextBlock x:Name="TitleText" Style="{DynamicResource T.Sub}" Margin="8,0,0,0" VerticalAlignment="Center" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
    </DockPanel>
    <DockPanel Grid.Row="1" Height="40" Margin="16,0,8,0">
      <StackPanel x:Name="ToolRight" DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center"/>
      <StackPanel x:Name="ToolLeft" Orientation="Horizontal" VerticalAlignment="Center"/>
    </DockPanel>
    <Border x:Name="Body" Grid.Row="2" Style="{DynamicResource SideWindow.Body}"/>
  </Grid>
</Window>
'@
}

# 결과: @{ Window; Title(TextBlock); ToolLeft; ToolRight; Body(Border) }. 보이기(Show)는 부르는 쪽이 한다
function New-WtSideWindow([string]$Title, [double]$Width = 640, [double]$Height = 560) {
    $xaml = Get-WtSideWindowXaml
    $w = ConvertFrom-WtXaml $xaml
    $owner = if (Get-Command Get-WtWindow -ErrorAction Ignore) { Get-WtWindow } else { $null }
    if ($owner -and $owner.IsVisible) { $w.Owner = $owner; $w.Resources.MergedDictionaries.Add($owner.Resources) }
    else { $w.WindowStartupLocation = 'CenterScreen'; $w.Resources.MergedDictionaries.Add((New-WtThemeDictionary)); $w.Resources.MergedDictionaries.Add((Get-WtStyleDictionary)) }
    $w.Width = $Width; $w.Height = $Height; $w.Title = $Title
    $named = Get-WtNamedElements $w $xaml
    $named.TitleText.Text = $Title
    $named.CloseButton.Add_Click({ param($s, $e) [System.Windows.Window]::GetWindow($s).Close() })
    $named.MaxButton.Add_Click({
            param($s, $e)
            $win = [System.Windows.Window]::GetWindow($s)
            $win.WindowState = if ($win.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
        })
    # 최대화하면 WindowChrome이 창 테두리만큼 화면 밖으로 그리므로 그만큼 안쪽으로 당긴다
    $w.Add_StateChanged({
            param($s, $e)
            $max = $s.WindowState -eq 'Maximized'
            $s.FindName('MaxGlyph').Text = [string][char]$(if ($max) { 0xE923 } else { 0xE922 })
            $s.FindName('MaxButton').ToolTip = if ($max) { '이전 크기로 복원' } else { '최대화' }
            $edge = [System.Windows.SystemParameters]::WindowResizeBorderThickness
            $s.FindName('Frame').Margin = if ($max) { [System.Windows.Thickness]::new($edge.Left + 2, $edge.Top + 2, $edge.Right + 2, $edge.Bottom + 2) } else { [System.Windows.Thickness]::new(0) }
        })
    @{ Window = $w; Title = $named.TitleText; ToolLeft = $named.ToolLeft; ToolRight = $named.ToolRight; Body = $named.Body }
}

Export-ModuleMember -Function New-WtSideWindow
