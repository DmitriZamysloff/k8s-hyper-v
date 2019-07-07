#Requires -RunAsAdministrator
echo "+-------------------------------------+"
echo "|   K8S CLUSTER CREATOR FOR HYPER-V   |"
echo "+-------------------------------------+"
$SEED_FILE = "k8s-hyper-v.seed"
$temDir = $env:temp    

function New-TemporaryDirectory {
    $parent = [System.IO.Path]::GetTempPath()
    [string] $name = [System.Guid]::NewGuid()
    New-Item -ItemType Directory -Path (Join-Path $parent $name)
}

function Get-BionicLinkAndVersion {
    $htmlFile = New-TemporaryFile
    wget http://releases.ubuntu.com/ -OutFile $htmlFile

    $theLine = Select-String -Path $htmlFile -Pattern Bionic | select -First 1
    $found = $theLine -match 'href=\"([\w\/]+)\"'
    $bionicLink = ''
    if ($found) {
        $bionicLink = $matches[1]
    }
    #Write-Host "Initial Line: [$($theLine)]"
    $theLine = $theLine -replace "\s+", " "
    #Write-Host "Initial Normalized: [$($theLine)]"
    $splitted = $theLine -split ' '
    #Write-Host "Splitted: [$($splitted)]"
    $bionicVersion = $splitted[6]
    #Write-Host "Version: [$($bionicVersion)]"
    return @($bionicLink, $bionicVersion)
}

function Get-Timezone-Online {
    $HTML = Invoke-WebRequest -Uri "https://www.iplocate.com/"
    $TREL = $HTML.ParsedHtml.getElementsByTagName("tr") | Where { $_.children[0].innerText -eq 'Timezone' }
    return $TREL.children[1].innerText
}

function Is-Yes-Response  {
    [OutputType([Boolean])] 
    Param (
        [parameter(Mandatory=$true)][String]$Prompt
    )

    while ("yes","no" -notcontains ($answer = Read-Host -Prompt "Remastered File $($NEW_ISO_FILE) already exists. Do remastering again? [yes|no]")) {
    }
    return "yes" -eq $answer
}

function Download-Version ($DownloadLocation, $DownloadFile, $TargetFolder) {
    $URI = "$($DownloadLocation)/$($DownloadFile)"
    Write-Host "Downloading file $($DownloadFile) from $($URI) to directory $($TargetFolder)" 
    wget $URI -OutFile "$($TargetFolder)/$($DownloadFile)" -Verbose 
} 

function Download-ISO (
        [String] $DownloadLocation,
        [String] $DownloadFile,
        [String] $TargetFolder
    ) {
    [String]$TargetIsoFile = "$($TargetFolder)\$($DownloadFile)"
    [Boolean] $do_download = ![System.IO.File]::Exists($TargetIsoFile)
    if ($do_download -eq $false) {
      $do_download = Is-Yes-Response "ISO File $($TargetIsoFile) already exists. Download again? [yes|no]"
    }
    if ($do_download -eq $true) {
        Download-Version $DownloadLocation $DownloadFile $TargetFolder
    }
}


function Get-Number-From-Input($Prompt) {
    do {
        try {
            $numOk = $true
            [int]$GetANumber = Read-Host -Prompt $Prompt
            } #end try
        catch {$numOk = $false}
        }#end do
    until(($GetANumber -ge 1 -and $GetANumber -lt 100) -and $numOk)
    return $GetANumber
}


function Remove-Dir-If-Exists ($Directory) {
    if (Test-Path -Path $Directory) {
        Remove-Item -Recurse -Force $Directory
    }
}

function Hash-String ([String] $String, [String] $HashName = "SHA512") {
    $StringBuilder = New-Object System.Text.StringBuilder
    [System.Security.Cryptography.HashAlgorithm]::Create($HashName).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($String))|%{[Void]$StringBuilder.Append($_.ToString("x2"))}
    return $StringBuilder.ToString()
}

function Create-New-Dir ($Directory) {
    Remove-Dir-If-Exists $Directory
    New-Item -ItemType "directory" $Directory
}

function Insert-Before ($FILE_PATH, $PATTERN, [String] $TO_INSERT) {
    [System.Collections.ArrayList]$file = Get-Content $FILE_PATH
    $insert = @()

    for ($i = 0; $i -lt $file.Count; $i++) {
        if ($file[$i] -match $PATTERN) {
            $insert += $i-1 #Recording the position
        }
    }
    $insert | ForEach-Object { $file.insert($_, $TO_INSERT) }

    Set-Content $FILE_PATH $file
}

function Do-Remaster ($WORK_FOLDER, $ISO_IMAGE_PATH, $NEW_ISO_FILE, [String] $SEED_FILE_NAME, $SEED_FILE_PATH, [String] $USER_NAME, [String] $PASSWORD, [String] $TIME_ZONE) {
    Write-Host "Remastering ISO File"
    $workFolder = "$($WORK_FOLDER)\iso_org"
    Create-New-Dir $workFolder
    if (Test-Path -Path $NEW_ISO_FILE) {
        Write-Host "Removing old remastered image $($NEW_ISO_FILE)"
        Remove-Item -Path $NEW_ISO_FILE
    }
    Write-Host "Mounting Disk Image $($ISO_IMAGE_PATH)"
    $mountResult = Mount-DiskImage -ImagePath $ISO_IMAGE_PATH -Access ReadOnly -PassThru 
    $mountLetter = ($mountResult|Get-Volume).DriveLetter
    Write-Host "Disk Image $($ISO_IMAGE_PATH) is mounted to $($mountLetter)"
    try {
        Write-Host "Copying ISO content $($mountLetter):\* to $($workFolder)"
        Copy-Item "$($mountLetter):\*" -Destination $workFolder -Recurse
    } finally {
        Write-Host "Dismounting Image"
        Dismount-DiskImage -ImagePath $ISO_IMAGE_PATH
    }
    #set language
    Write-Host "Setting new installation language to 'en'"
    Echo "en" > $workFolder\iso_new\isolinux\lang
    Write-Host "Setting timeout in $($workFolder)/iso_new/isolinux.cfg to 1"
    (Get-Content $workFolder\iso_new\isolinux\isolinux.cfg) -replace "\stimeout\s+([0-9]+)","1" | Out-File $workFolder\iso_new\isolinux\isolinux.cfg
    
    $lateCommand = "chroot /target curl -L /home/$($USER_NAME)/start.sh https://raw.githubusercontent.com/DmitriZamysloff/k8s-hyper-v/master/start.sh ; chroot /target chmod +x /home/$($USER_NAME)/start.sh ;"
    
    Write-Host "Copying seed file $($SEED_FILE_PATH) to $($workFolder)/iso_new/preceed/$($SEED_FILE_NAME)"
    Copy-Item $SEED_FILE_PATH -Destination $workFolder\iso_new\preceed\$SEED_FILE_NAME
    Write-Host "Setting up firstrun script"
    Echo "d-i preseed/late_command                              string $($lateCommand)" >> $workFolder\iso_new\preseed\$SEED_FILE_NAME
    [String] $PASSWORD_HASH = Hash-String $PASSWORD
    (Get-Content $workFolder\iso_new\preceed/$SEED_FILE_NAME) -replace "{{username}}","$($USER_NAME)" -replace "{{pwhash}}", $PASSWORD_HASH -replace "{{hostname}}","vubuntu" -replace "{{timezone}}",$TIME_ZONE | Out-File $workFolder\iso_new\preceed\$SEED_FILE_NAME

    $SEED_CHECKSUM = Get-FileHash $workFolder\iso_new\preceed\$SEED_FILE_NAME -Algorithm MD5

    Insert-Before $workFolder\iso_new\isolinux\txt.cfg "^label install$" "label autoinstall`n  menu label ^Autoinstall V-K8S Ubuntu Server`n  kernel /install/vmlinuz`n  append file=/cdrom/preseed/ubuntu-server.seed initrd=/install/initrd.gz auto=true priority=high preseed/file=/cdrom/preseed/$($SEED_FILE_NAME) preseed/file/checksum=$($SEED_CHECKSUM) --`n"


}



$bL,$bV = Get-BionicLinkAndVersion
$DOWNLOAD_FILE = "ubuntu-$($bV)-server-amd64.iso"
$DOWNLOAD_LOCATION = "http://cdimage.ubuntu.com/releases/$($bL)release"
$NEW_ISO_NAME = "ubuntu-$($bV)-server-amd64-unattended.iso"

if (($userName = Read-Host -Prompt "Please Input Preferred User Name [bionic]") -eq '') {$username = "bionic"} 
if (($password = Read-Host -Prompt "Please Enter Preferred Password for User $($userName) [bionic]") -eq '') {$password = "bionic"}
if ($password -ne 'bionic') {
    $password2 = Read-Host -Prompt "Please Re-Enter Password"
    if ($password -ne $password2) {
        Write-Host "you password do not match. Please restart script."
        return
     }
 }

$timeZoneFound = Get-Timezone-Online
if (($TIMEZONE = Read-Host -Prompt "Please Enter Desired Timezone [$($timeZoneFound)]") -eq '') {$TIMEZONE = $timeZoneFound}


$NUM_OF_WORKERS = Get-Number-From-Input "How many workers would you like to configure?"

$ISO_FILE = "$($temDir)\$($DOWNLOAD_FILE)"
$NEW_ISO_FILE = "$($temDir)\$($NEW_ISO_NAME)"
$SEED_FILE_PATH = "$($temDir)\$($SEED_FILE)"

Download-ISO $DOWNLOAD_LOCATION $DOWNLOAD_FILE $temDir

if (![System.IO.File]::Exists($ISO_FILE)) {
    Write-Host "Error downloading file"
    return
}


Write-Host "Downloading $($SEED_FILE)"
wget "https://raw.githubusercontent.com/DmitriZamysloff/k8s-hyper-v/master/$($SEED_FILE)" -OutFile $SEED_FILE_PATH

[Boolean] $do_remaster = ![System.IO.File]::Exists($NEW_ISO_FILE)

if ($do_remaster -eq $false) {
    $do_remaster = Is-Yes-Response "Remastered File $($NEW_ISO_FILE) already exists. Do remastering again? [yes|no]"
}
if ($do_remaster -eq $true) {
    Write-Host "Remastering ISO File"
    Do-Remaster $temDir $ISO_FILE $SEED_FILE $SEED_FILE_PATH $userName $password $TIMEZONE
}



