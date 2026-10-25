# 공통 부품. 버튼 · 입력 칸 · 카드 · 메뉴 항목 같은 모양은 여기서만 정한다.
# 기능(애드온) 모듈은 아래 New-Wt* 함수와 스타일 이름만 쓰고, 색 값이나 글꼴 이름을 직접 쓰지 않는다.
# 색 · 크기는 Theme.psm1의 리소스(B.* · F.* · Font.*)를 DynamicResource로 참조해서, 테마를 바꾸면 바로 반영된다.

$ErrorActionPreference = 'Stop'

$script:ns = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'

# 스타일 모음. 색은 Style.Triggers에서 바꾼다 (템플릿 트리거로 바꾸면 BasedOn 스타일에서 덮어쓸 수 없어서).
$script:stylesXaml = @'
<ResourceDictionary {NS}>

  <Style x:Key="T.Body" TargetType="TextBlock">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
  </Style>
  <Style x:Key="T.Sub" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontSize" Value="{DynamicResource F.Small}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
  </Style>
  <Style x:Key="T.Title" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontSize" Value="{DynamicResource F.Title}"/>
    <Setter Property="FontWeight" Value="Bold"/>
  </Style>
  <Style x:Key="T.H2" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontSize" Value="{DynamicResource F.H2}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
  </Style>
  <Style x:Key="T.Number" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontSize" Value="{DynamicResource F.Number}"/>
    <Setter Property="FontWeight" Value="Bold"/>
  </Style>
  <Style x:Key="T.Dialog" TargetType="TextBlock" BasedOn="{StaticResource T.H2}">
    <Setter Property="FontSize" Value="{DynamicResource F.Dialog}"/>
  </Style>
  <Style x:Key="T.Strong" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontWeight" Value="SemiBold"/>
  </Style>
  <Style x:Key="T.Icon" TargetType="TextBlock">
    <Setter Property="FontFamily" Value="{DynamicResource Font.Icon}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Icon}"/>
    <Setter Property="VerticalAlignment" Value="Center"/>
    <Setter Property="HorizontalAlignment" Value="Center"/>
  </Style>

  <Style x:Key="Card" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CornerRadius" Value="12"/>
    <Setter Property="Padding" Value="20,16"/>
  </Style>
  <Style x:Key="Tile" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource B.WindowBg}"/>
    <Setter Property="CornerRadius" Value="10"/>
    <Setter Property="Padding" Value="14,10"/>
  </Style>
  <Style x:Key="Divider" TargetType="Border">
    <Setter Property="BorderBrush" Value="{DynamicResource B.Divider}"/>
    <Setter Property="BorderThickness" Value="0,1,0,0"/>
  </Style>

  <Style x:Key="Btn" TargetType="Button">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.ButtonBorder}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="16,0"/>
    <Setter Property="MinHeight" Value="40"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="False"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Hover}"/>
      </Trigger>
      <Trigger Property="IsKeyboardFocused" Value="True">
        <Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False">
        <Setter Property="Opacity" Value="0.5"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Btn.Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Background" Value="{DynamicResource B.Accent}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.OnAccent}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.AccentHover}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource B.AccentHover}"/>
      </Trigger>
      <Trigger Property="IsKeyboardFocused" Value="True">
        <Setter Property="BorderBrush" Value="{DynamicResource B.Text}"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Btn.Danger" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Danger}"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.DangerBg}"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Btn.Link" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Foreground" Value="{DynamicResource B.AccentStrong}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Small}"/>
    <Setter Property="MinHeight" Value="32"/>
    <Setter Property="Padding" Value="10,0"/>
  </Style>
  <Style x:Key="Btn.Icon" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Foreground" Value="{DynamicResource B.NavText}"/>
    <Setter Property="Width" Value="40"/>
    <Setter Property="Height" Value="40"/>
    <Setter Property="MinHeight" Value="0"/>
    <Setter Property="Padding" Value="0"/>
  </Style>
  <Style x:Key="Btn.Chrome" TargetType="Button" BasedOn="{StaticResource Btn.Icon}">
    <Setter Property="Width" Value="46"/>
    <Setter Property="Height" Value="40"/>
  </Style>
  <Style x:Key="Btn.Close" TargetType="Button" BasedOn="{StaticResource Btn.Chrome}">
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.CloseHover}"/>
        <Setter Property="Foreground" Value="#FFFFFF"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style x:Key="Nav" TargetType="RadioButton">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.NavText}"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Height" Value="40"/>
    <Setter Property="Margin" Value="0,2"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="12,0">
            <ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="False"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Hover}"/>
      </Trigger>
      <Trigger Property="IsChecked" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.AccentSoft}"/>
        <Setter Property="Foreground" Value="{DynamicResource B.AccentStrong}"/>
        <Setter Property="FontWeight" Value="SemiBold"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style x:Key="Seg" TargetType="RadioButton">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.ChipText}"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="MinHeight" Value="34"/>
    <Setter Property="Padding" Value="14,0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="False"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="IsChecked" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Card}"/>
        <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
        <Setter Property="FontWeight" Value="SemiBold"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style x:Key="Swatch" TargetType="RadioButton">
    <Setter Property="Width" Value="40"/>
    <Setter Property="Height" Value="40"/>
    <Setter Property="Margin" Value="0,0,6,0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Grid Background="Transparent">
            <Ellipse x:Name="Ring" Stroke="{DynamicResource B.Text}" StrokeThickness="2" Visibility="Hidden"/>
            <Ellipse Margin="6" Fill="{TemplateBinding Background}" Stroke="{TemplateBinding BorderBrush}" StrokeThickness="1"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Ring" Property="Visibility" Value="Visible"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="Input" TargetType="TextBox">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.InputBorder}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="10,8"/>
    <Setter Property="MinHeight" Value="40"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
            <!-- 안쪽 여백(Padding)은 TextBox가 글자 둘레에 스스로 넣는다. 여기서 또 넣으면 두 배가 된다 -->
            <ScrollViewer x:Name="PART_ContentHost" Focusable="False"
                          VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="IsKeyboardFocused" Value="True">
        <Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/>
      </Trigger>
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
  </Style>
  <!-- 실행 출력: 코드 바탕의 읽기 전용 여러 줄. 줄을 바꾸지 않고 가로로 스크롤한다 (스크립트 출력 등) -->
  <Style x:Key="Output" TargetType="TextBox" BasedOn="{StaticResource Input}">
    <Setter Property="IsReadOnly" Value="True"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Background" Value="{DynamicResource B.Code.Bg}"/>
    <Setter Property="FontFamily" Value="{DynamicResource Font.Mono}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Code}"/>
    <Setter Property="Padding" Value="12,8"/>
    <Setter Property="TextWrapping" Value="NoWrap"/>
    <Setter Property="AcceptsReturn" Value="True"/>
    <Setter Property="VerticalContentAlignment" Value="Top"/>
    <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
    <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
  </Style>

  <!-- 고르기 칸(ComboBox): 입력칸과 같은 테두리 · 높이 · 모서리. 펼친 목록은 카드 모양 -->
  <Style x:Key="Combo.Item" TargetType="ComboBoxItem">
    <Setter Property="Padding" Value="10,8"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ComboBoxItem">
          <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}" Margin="4,1">
            <ContentPresenter/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsHighlighted" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.Hover}"/>
            </Trigger>
            <Trigger Property="IsSelected" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.AccentSoft}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Combo" TargetType="ComboBox">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.InputBorder}"/>
    <Setter Property="MinHeight" Value="40"/>
    <Setter Property="Padding" Value="10,8,32,8"/>
    <Setter Property="ItemContainerStyle" Value="{StaticResource Combo.Item}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ComboBox">
          <Grid>
            <ToggleButton Focusable="False" ClickMode="Press"
                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
              <ToggleButton.Template>
                <ControlTemplate TargetType="ToggleButton">
                  <Border x:Name="Bd" CornerRadius="8" BorderThickness="1"
                          Background="{Binding Background, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                          BorderBrush="{Binding BorderBrush, RelativeSource={RelativeSource AncestorType=ComboBox}}">
                    <TextBlock Text="&#xE70D;" FontFamily="{DynamicResource Font.Icon}" FontSize="12" Foreground="{DynamicResource B.SubText}"
                               HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                      <Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.Hover}"/>
                    </Trigger>
                  </ControlTemplate.Triggers>
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
              <Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter Property="Opacity" Value="0.5"/>
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
    <Setter Property="Background" Value="{DynamicResource B.Chip}"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="IsIndeterminate" Value="True"/>
  </Style>

  <!-- 편집 칸: 카드 안을 채우는 테두리 없는 여러 줄 입력 (메모 본문 등) -->
  <Style x:Key="Editor" TargetType="TextBox" BasedOn="{StaticResource Input}">
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Padding" Value="0"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
    <Setter Property="AcceptsReturn" Value="True"/>
    <Setter Property="AcceptsTab" Value="True"/>
    <Setter Property="VerticalContentAlignment" Value="Top"/>
    <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
  </Style>
  <!-- 제목 입력: 글자처럼 보이는 한 줄 입력 (포커스가 가면 아래 선이 강조색) -->
  <Style x:Key="Input.Title" TargetType="TextBox" BasedOn="{StaticResource Input}">
    <Setter Property="BorderThickness" Value="0,0,0,1"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Padding" Value="0,2"/>
    <Setter Property="MinHeight" Value="0"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Number}"/>
    <Setter Property="FontWeight" Value="Bold"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="BorderBrush" Value="{DynamicResource B.InputBorder}"/>
      </Trigger>
      <Trigger Property="IsKeyboardFocused" Value="True">
        <Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style x:Key="Row" TargetType="ListBoxItem">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Padding" Value="12,10"/>
    <Setter Property="Margin" Value="0,1"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ListBoxItem">
          <Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Hover}"/>
      </Trigger>
      <Trigger Property="IsSelected" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.AccentSoft}"/>
      </Trigger>
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
        <TextBlock DockPanel.Dock="Right" Text="{Binding Stamp}" Style="{DynamicResource T.Sub}" Margin="8,0,0,0"/>
        <TextBlock Text="{Binding Title}" Style="{DynamicResource T.Strong}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
      </DockPanel>
      <TextBlock Text="{Binding Snippet}" Style="{DynamicResource T.Sub}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
    </StackPanel>
  </DataTemplate>
  <Style x:Key="Memo.List" TargetType="ListBox" BasedOn="{StaticResource List}">
    <Setter Property="ItemTemplate" Value="{StaticResource Memo.Item}"/>
  </Style>
  <Style x:Key="Doc.Row" TargetType="ListBoxItem" BasedOn="{StaticResource Row}">
    <Setter Property="Padding" Value="12,6"/>
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
    <Setter Property="Padding" Value="4,6,10,6"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TreeViewItem">
          <StackPanel>
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}" Margin="0,1"
                    BorderBrush="Transparent" BorderThickness="1">
              <DockPanel>
                <ToggleButton x:Name="Expander" DockPanel.Dock="Left" Style="{StaticResource TreeExpander}" ClickMode="Press"
                              IsChecked="{Binding IsExpanded, RelativeSource={RelativeSource TemplatedParent}}"/>
                <ContentPresenter ContentSource="Header" VerticalAlignment="Center" Margin="4,0,0,0" RecognizesAccessKey="False"/>
              </DockPanel>
            </Border>
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

  <!-- 체크 상자: 표의 선택 상자(Task.Check)와 같은 16 상자 + 오른쪽 글자. 글자를 눌러도 바뀐다 -->
  <Style x:Key="Check" TargetType="CheckBox">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Margin" Value="0,4"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
      <DockPanel Background="Transparent">
        <Border x:Name="Box" DockPanel.Dock="Left" Width="16" Height="16" VerticalAlignment="Center"
          CornerRadius="4" Background="{DynamicResource B.Card}" BorderBrush="{DynamicResource B.InputBorder}" BorderThickness="1">
          <Grid>
            <Path x:Name="Mark" Data="M 2,7 L 6,11 L 12,3" Stroke="{DynamicResource B.OnAccent}" StrokeThickness="2" Visibility="Collapsed"/>
            <Border x:Name="Dash" Width="8" Height="2" Background="{DynamicResource B.OnAccent}" Visibility="Collapsed"/>
          </Grid>
        </Border>
        <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="False"/>
      </DockPanel>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource B.SubText}"/></Trigger>
        <Trigger Property="IsChecked" Value="True"><Setter TargetName="Box" Property="Background" Value="{DynamicResource B.Accent}"/><Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource B.Accent}"/><Setter TargetName="Mark" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsChecked" Value="{x:Null}"><Setter TargetName="Box" Property="Background" Value="{DynamicResource B.Accent}"/><Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource B.Accent}"/><Setter TargetName="Dash" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource B.Text}"/><Setter TargetName="Box" Property="BorderThickness" Value="2"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
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
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
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
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- 겹쳐 뜨는 패널(좁은 창에서 내용 위에 여는 설명 패널 등)의 그림자. 패널에 바로 걸면 패널 글자까지 그림 한 장으로 다시 그려져서, 패널 뒤에 따로 깐다 -->
  <Style x:Key="Overlay.Shadow" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="CornerRadius" Value="12"/>
    <Setter Property="Effect">
      <Setter.Value>
        <DropShadowEffect BlurRadius="16" ShadowDepth="8" Direction="270" Opacity="0.14" Color="#000000"/>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- 마크다운 보기 (Markdown.psm1). 문서 요소(Paragraph · Section · Run …)의 모양 -->
  <!-- RichTextBox는 배치할 때 문서 좌우에 5씩 여백을 넣는다(PagePadding 5,0). 안쪽 여백 -5로 없애서 옆 글과 줄을 맞춘다 -->
  <Style x:Key="Md.View" TargetType="RichTextBox">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Padding" Value="-5,0,-5,0"/>
    <Setter Property="AcceptsTab" Value="False"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="HorizontalScrollBarVisibility" Value="Disabled"/>
  </Style>
  <Style x:Key="Md.Doc" TargetType="FlowDocument">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.BodyLine}"/>
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
    <Setter Property="FontSize" Value="{DynamicResource F.MdH1}"/>
    <Setter Property="FontWeight" Value="Bold"/>
    <Setter Property="LineHeight" Value="Auto"/>
    <Setter Property="Margin" Value="0,24,0,12"/>
  </Style>
  <Style x:Key="Md.H2" TargetType="Paragraph" BasedOn="{StaticResource Md.H1}">
    <Setter Property="FontSize" Value="{DynamicResource F.MdH2}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Margin" Value="0,24,0,8"/>
  </Style>
  <Style x:Key="Md.H3" TargetType="Paragraph" BasedOn="{StaticResource Md.H2}">
    <Setter Property="FontSize" Value="{DynamicResource F.MdH3}"/>
    <Setter Property="Margin" Value="0,16,0,8"/>
  </Style>
  <Style x:Key="Md.H4" TargetType="Paragraph" BasedOn="{StaticResource Md.H2}">
    <Setter Property="FontSize" Value="{DynamicResource F.H2}"/>
    <Setter Property="Margin" Value="0,16,0,4"/>
  </Style>
  <Style x:Key="Md.H5" TargetType="Paragraph" BasedOn="{StaticResource Md.H4}">
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
  </Style>
  <Style x:Key="Md.H6" TargetType="Paragraph" BasedOn="{StaticResource Md.H5}">
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
    <Setter Property="FontSize" Value="{DynamicResource F.Code}"/>
    <Setter Property="LineHeight" Value="Auto"/>
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
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="CaretBrush" Value="{DynamicResource B.Text}"/>
    <Setter Property="TextBlock.LineHeight" Value="{DynamicResource F.BodyLine}"/>
    <Setter Property="TextBlock.LineStackingStrategy" Value="BlockLineHeight"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
    <Setter Property="AcceptsReturn" Value="True"/>
    <Setter Property="AcceptsTab" Value="True"/>
    <Setter Property="VerticalScrollBarVisibility" Value="Disabled"/>
    <Setter Property="HorizontalScrollBarVisibility" Value="Disabled"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="HorizontalAlignment" Value="Stretch"/>
  </Style>
  <Style x:Key="Memo.IslandH1" TargetType="TextBox" BasedOn="{StaticResource Memo.Island}">
    <Setter Property="FontSize" Value="{DynamicResource F.MdH1}"/>
    <Setter Property="FontWeight" Value="Bold"/>
    <Setter Property="TextBlock.LineHeight" Value="Auto"/>
  </Style>
  <Style x:Key="Memo.IslandH2" TargetType="TextBox" BasedOn="{StaticResource Memo.IslandH1}">
    <Setter Property="FontSize" Value="{DynamicResource F.MdH2}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
  </Style>
  <Style x:Key="Memo.IslandH3" TargetType="TextBox" BasedOn="{StaticResource Memo.IslandH2}">
    <Setter Property="FontSize" Value="{DynamicResource F.MdH3}"/>
  </Style>
  <Style x:Key="Memo.IslandH4" TargetType="TextBox" BasedOn="{StaticResource Memo.IslandH2}">
    <Setter Property="FontSize" Value="{DynamicResource F.H2}"/>
  </Style>
  <Style x:Key="Memo.IslandH5" TargetType="TextBox" BasedOn="{StaticResource Memo.IslandH4}">
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
  </Style>
  <Style x:Key="Memo.IslandH6" TargetType="TextBox" BasedOn="{StaticResource Memo.IslandH5}">
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
  </Style>
  <Style x:Key="Memo.IslandCode" TargetType="TextBox" BasedOn="{StaticResource Memo.Island}">
    <Setter Property="FontFamily" Value="{DynamicResource Font.Mono}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Code}"/>
    <Setter Property="TextBlock.LineHeight" Value="Auto"/>
    <Setter Property="Background" Value="{DynamicResource B.Code.Bg}"/>
    <Setter Property="Padding" Value="12,8"/>
  </Style>
  <!-- 섬을 담는 블록: 그린 문단과 같은 아래 여백 -->
  <Style x:Key="Memo.IslandBox" TargetType="BlockUIContainer">
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>

  <Style x:Key="Task.Check" TargetType="CheckBox">
    <Setter Property="VerticalAlignment" Value="Center"/>
    <Setter Property="HorizontalAlignment" Value="Stretch"/>
    <Setter Property="Padding" Value="12,8"/>
    <Setter Property="MinHeight" Value="32"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
      <Border x:Name="HitArea" Padding="{TemplateBinding Padding}" Background="Transparent">
        <Border x:Name="Box" Width="16" Height="16" HorizontalAlignment="Left" VerticalAlignment="Center"
          CornerRadius="4" Background="{DynamicResource B.Card}" BorderBrush="{DynamicResource B.InputBorder}" BorderThickness="1">
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
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Task.Row" TargetType="DataGridRow">
    <Setter Property="MinHeight" Value="32"/>
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="BorderThickness" Value="3,0,0,0"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Style.Triggers>
      <DataTrigger Binding="{Binding Selected}" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.AccentSoft}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/>
      </DataTrigger>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource B.Hover}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Task.Cell" TargetType="DataGridCell">
    <Setter Property="Padding" Value="12,4"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="Background" Value="Transparent"/>
    <Style.Triggers>
      <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/></Trigger>
      <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource B.AccentSoft}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Task.Header" TargetType="DataGridColumnHeader">
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Padding" Value="12,8"/>
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="0,0,0,1"/>
  </Style>
  <Style x:Key="Task.Text" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="TextWrapping" Value="NoWrap"/>
    <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    <Setter Property="VerticalAlignment" Value="Center"/>
    <Setter Property="ToolTip" Value="{Binding RelativeSource={RelativeSource Self}, Path=Text}"/>
  </Style>
</ResourceDictionary>
'@

$script:styles = $null

# 스타일 사전 (처음 부를 때 한 번 만든다)
function Get-WtStyleDictionary {
    if (-not $script:styles) {
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
        $b.Add_Click({ param($s, $e) Select-WtPage $s.Tag })
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
    $box.CornerRadius = [System.Windows.CornerRadius]::new(10)
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
function New-WtSearchBox([string]$Hint = '검색') {
    $g = [System.Windows.Controls.Grid]::new()
    $box = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $box 'Input'
    $box.Padding = [System.Windows.Thickness]::new(36, 8, 10, 8)
    $icon = New-WtIcon 0xE721
    Set-WtResource $icon 'Foreground' 'B.SubText'
    $icon.HorizontalAlignment = 'Left'
    $icon.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
    $icon.IsHitTestVisible = $false
    $hintText = New-WtText $Hint 'T.Sub'   # $hint로 쓰면 [string]$Hint와 같은 변수가 된다
    $hintText.VerticalAlignment = 'Center'
    $hintText.Margin = [System.Windows.Thickness]::new(38, 0, 0, 0)
    $hintText.IsHitTestVisible = $false
    $box.Tag = $hintText
    $box.Add_TextChanged({ param($s, $e) $s.Tag.Visibility = if ($s.Text) { 'Collapsed' } else { 'Visible' } })
    [void]$g.Children.Add($box)
    [void]$g.Children.Add($icon)
    [void]$g.Children.Add($hintText)
    @{ Root = $g; Box = $box }
}

# 작은 알약 모양 표시. $Bg/$Fg는 테마 리소스 이름 (예: 'Att.WorkBg', 'Att.Work')
function New-WtTag([string]$Text, [string]$Bg = 'Chip', [string]$Fg = 'ChipText', [int]$Icon = 0) {
    $b = [System.Windows.Controls.Border]::new()
    $b.CornerRadius = [System.Windows.CornerRadius]::new(12)
    $b.Padding = [System.Windows.Thickness]::new(9, 2, 9, 3)
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
    $t.FontWeight = 'SemiBold'
    $t.TextWrapping = 'NoWrap'
    [void](Add-WtChild $row $t)
    $b.Child = $row
    $b
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
    $d.Margin = [System.Windows.Thickness]::new(0, 0, 0, 20)
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
        $dock.Margin = [System.Windows.Thickness]::new(36, 8, 36, 32)
        return @{ Root = $dock; Panel = $dock }
    }
    $sv = [System.Windows.Controls.ScrollViewer]::new()
    $sv.VerticalScrollBarVisibility = 'Auto'
    $sv.HorizontalScrollBarVisibility = 'Disabled'
    $sv.Focusable = $false
    $panel = New-WtStack Vertical 16
    $panel.Margin = [System.Windows.Thickness]::new(36, 8, 36, 32)
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
  HeadersVisibility="Column" SelectionMode="Single" SelectionUnit="FullRow" BorderThickness="0"
  Background="{DynamicResource B.Card}" Foreground="{DynamicResource B.Text}"
  FontFamily="{DynamicResource Font.UI}" FontSize="{DynamicResource F.Body}"
  RowStyle="{DynamicResource Task.Row}" CellStyle="{DynamicResource Task.Cell}" ColumnHeaderStyle="{DynamicResource Task.Header}"
  GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="{DynamicResource B.Divider}"
  EnableRowVirtualization="True" EnableColumnVirtualization="True"
  VirtualizingPanel.IsVirtualizingWhenGrouping="True" VirtualizingPanel.VirtualizationMode="Recycling" ScrollViewer.CanContentScroll="True">
  <DataGrid.Columns>
    <DataGridTemplateColumn Header="선택" Width="48" CanUserSort="False">
      <DataGridTemplateColumn.CellTemplate><DataTemplate>
        <CheckBox Tag="task" Style="{DynamicResource Task.Check}" IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
          IsEnabled="{Binding CanClose}" ToolTip="{Binding CloseHint}" AutomationProperties.Name="{Binding DisplayTitle}"/>
      </DataTemplate></DataGridTemplateColumn.CellTemplate>
    </DataGridTemplateColumn>
    <DataGridTextColumn Header="이름" Binding="{Binding DisplayTitle}" SortMemberPath="DisplayTitle" Width="*" MinWidth="200" ElementStyle="{DynamicResource Task.Text}"/>
    <DataGridTextColumn Header="종류" Binding="{Binding KindLabel}" SortMemberPath="KindLabel" Width="80" ElementStyle="{DynamicResource Task.Text}"/>
    <DataGridTextColumn Header="창" Binding="{Binding WindowLabel}" SortMemberPath="WindowNumber" Width="96" ElementStyle="{DynamicResource Task.Text}"/>
    <DataGridTextColumn Header="상태" Binding="{Binding Status}" SortMemberPath="Status" Width="240" ElementStyle="{DynamicResource Task.Text}"/>
  </DataGrid.Columns>
  <DataGrid.GroupStyle><GroupStyle>
    <GroupStyle.ContainerStyle><Style TargetType="GroupItem"><Setter Property="Template"><Setter.Value>
      <ControlTemplate TargetType="GroupItem">
        <Expander Tag="task-group" IsExpanded="True" Background="{DynamicResource B.Sidebar}" Foreground="{DynamicResource B.Text}">
          <Expander.Header><StackPanel Orientation="Horizontal">
            <CheckBox Tag="group" IsThreeState="True" Style="{DynamicResource Task.Check}" AutomationProperties.Name="{Binding Name}"/>
            <TextBlock Text="{Binding Name}" Style="{DynamicResource T.Strong}" VerticalAlignment="Center"/>
            <TextBlock Text="{Binding ItemCount}" Style="{DynamicResource T.Sub}" Margin="16,0,4,0" VerticalAlignment="Center"/>
            <TextBlock Text="개 표시" Style="{DynamicResource T.Sub}" VerticalAlignment="Center"/>
          </StackPanel></Expander.Header>
          <ItemsPresenter/>
        </Expander>
      </ControlTemplate>
    </Setter.Value></Setter></Style></GroupStyle.ContainerStyle>
  </GroupStyle></DataGrid.GroupStyle>
</DataGrid>
'@
    # 그룹 행의 ItemsPresenter가 무한 폭으로 측정돼도 이름 열이 남는 폭을 채운다.
    $grid.Add_SizeChanged({ param($s, $e) $s.Columns[1].Width = [System.Windows.Controls.DataGridLength]::new([Math]::Max(200, $s.ActualWidth - 48 - 80 - 96 - 240 - 24)) })
    $grid
}

function New-WtTaskPage {
    $page = New-WtPage -Fill
    $page.Root.Margin = [System.Windows.Thickness]::new(24, 8, 24, 24)
    $page
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

Export-ModuleMember -Function Get-WtUiWorkBudget, New-WtPollTimer, New-WtTaskGrid, New-WtTaskPage, New-WtModal, New-WtMinuteInput, New-WtContextMenu, Get-WtVisualChild,
    Get-WtStyleDictionary, ConvertFrom-WtXaml, Get-WtNamedElements, Set-WtStyle, Set-WtResource,
    New-WtText, New-WtIcon, New-WtStack, Add-WtChild, New-WtCard, New-WtCardHeader, New-WtButton, New-WtButtonContent, New-WtSegmented, New-WtSearchBox, New-WtTag,
    New-WtStatTile, New-WtPageHeader, New-WtPage, New-WtListRow, Format-WtDate, Show-WtMessage, Confirm-WtYesNo, Show-WtError
