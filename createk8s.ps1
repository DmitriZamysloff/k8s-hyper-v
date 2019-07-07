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

function Is-Yes-Response ([String] $Prompt) {
    while ("yes","no" -notcontains ($answer = Read-Host -Prompt $Prompt)) {
    }
    if ("yes" -eq $answer) {
        return $true
    }
    return $false
}

function Download-Version ($DownloadLocation, $DownloadFile, $TargetFolder) {
    $URI = "$($DownloadLocation)/$($DownloadFile)"
    Write-Host "Downloading file $($DownloadFile) from $($URI) to directory $($TargetFolder)" 
    wget $URI -OutFile "$($TargetFolder)/$($DownloadFile)" -Verbose 
} 

function Download-ISO ($DownloadLocation, $DownloadFile, $TargetFolder) {
    [String]$TargetIsoFile = "$($TargetFolder)\$($DownloadFile)"
    [Boolean] $do_iso_download = ![System.IO.File]::Exists($TargetIsoFile)
    if (!($do_iso_download)) {
        $do_iso_download = Is-Yes-Response "ISO File $($TargetIsoFile) already exists. Download again? [yes|no]"
    }
    if ($do_iso_download -eq $true) {
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
        Write-Host "Removing old directory $($Directory)"
        Remove-Item -Recurse -Force $Directory
    }
}

function Create-New-Dir ($Directory) {
    Remove-Dir-If-Exists $Directory
    New-Item -ItemType "directory" $Directory
}

function Insert-Before ($FILE_PATH, $PATTERN, [String] $TO_INSERT) {
    Write-Host "Tracing file $($FILE_PATH) for suitable positions"
    [System.Collections.ArrayList]$file = Get-Content $FILE_PATH
    $insert = @()

    for ($i = 0; $i -lt $file.Count; $i++) {
        if ($file[$i] -match $PATTERN) {
            $position = $i#$i-1
            $insert += $position #Recording the position
            Write-Host "String at position $($i) ->[$($file[$i])]<- matched. Position $($position) added"
        }
    }
    $insert | ForEach-Object { $file.insert($_, $TO_INSERT) }

    Set-Content $FILE_PATH $file
}

function Hash-PWD ([String] $PWD) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 #the site works with old protocol
    $Headers = @{
        Accept = "*/*"
        Host = "www.mkpasswd.net"
        "Accept-Encoding" = "gzip, deflate"
        "User-Agent" = "Runtime/7.15.0"
        "Cache-Control" = "no-cache"
    }
    $Form = @{
        data=$($PWD)
        type="crypt-sha512"
        action="Hash"
    }
    $HTML = Invoke-WebRequest -Uri "https://www.mkpasswd.net/index.php" -Method Post -Headers $Headers -Body $Form -ContentType "application/x-www-form-urlencoded"
    return ($HTML.ParsedHtml.getElementsByTagName("input") | Where { $_.type -eq "text" -and $_.readOnly -eq $true}).value
}

function Make-RW ([String] $FILE) {
    attrib -r $FILE
}

function Do-Remaster ($WORK_FOLDER, $ISO_IMAGE_PATH, $NEW_ISO_FILE, [String] $SEED_FILE_NAME, $SEED_FILE_PATH, [String] $USER_NAME, [String] $PASSWORD, [String] $TIME_ZONE) {
    
    $workFolder = "$($WORK_FOLDER)\iso_org"
    Write-Host "Remastering ISO File in $($workFolder)"
    
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
        Copy-Item "$($mountLetter):\*" -Destination $workFolder -Recurse | Out-Null
    } finally {
        Write-Host "Dismounting Image"
        Dismount-DiskImage -ImagePath $ISO_IMAGE_PATH
    }
    #set language
    Write-Host "Setting new installation language to 'en'"
    Make-RW "$($workFolder)\isolinux\lang"
    Echo "en" | Out-File $workFolder\isolinux\lang
    Write-Host "Setting timeout in $($workFolder)/isolinux/isolinux.cfg to 1"
    Make-RW "$($workFolder)\isolinux\isolinux.cfg"
    (Get-Content $workFolder\isolinux\isolinux.cfg) -replace "^timeout\s+([0-9]+)$","timeout 1" | Out-File $workFolder\isolinux\isolinux.cfg
    
    $lateCommand = "chroot /target curl -L /home/$($USER_NAME)/start.sh https://raw.githubusercontent.com/DmitriZamysloff/k8s-hyper-v/master/start.sh ; chroot /target chmod +x /home/$($USER_NAME)/start.sh ;"
    
    Write-Host "Copying seed file $($SEED_FILE_PATH) to $($workFolder)\preseed"
    Copy-Item $SEED_FILE_PATH -Destination $workFolder\preseed
    Write-Host "Setting up firstrun script"
    Echo "d-i preseed/late_command                              string $($lateCommand)" >> $workFolder\preseed\$SEED_FILE_NAME
    [String] $PASSWORD_HASH = Hash-PWD $PASSWORD
    (Get-Content $workFolder\preseed\$SEED_FILE_NAME) -replace "{{username}}","$($USER_NAME)" -replace "{{pwhash}}", $PASSWORD_HASH -replace "{{hostname}}","vubuntu" -replace "{{timezone}}",$TIME_ZONE | Out-File $workFolder\preseed\$SEED_FILE_NAME

    $SEED_CHECKSUM = Get-FileHash $workFolder\preseed\$SEED_FILE_NAME -Algorithm MD5
    $SEED_HASH = $SEED_CHECKSUM.Hash.toLower()
    Make-RW "$($workFolder)\isolinux\txt.cfg"
    Insert-Before $workFolder\isolinux\txt.cfg "^label install$" "label autoinstall`n  menu label ^Autoinstall V-K8S Ubuntu Server`n  kernel /install/vmlinuz`n  append file=/cdrom/preseed/ubuntu-server.seed initrd=/install/initrd.gz auto=true priority=high preseed/file=/cdrom/preseed/$($SEED_FILE_NAME) preseed/file/checksum=$($SEED_HASH)  /home/$($USER_NAME)/iso_new/preseed/$($SEED_FILE_NAME) --"


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

if (!($do_remaster)) {
    $do_remaster = Is-Yes-Response "Remastered File $($NEW_ISO_FILE) already exists. Do remastering again? [yes|no]"
} else {
    Write-Host "No remastered file found."
}
if ($do_remaster) {
    Do-Remaster $temDir $ISO_FILE $NEW_ISO_FILE $SEED_FILE $SEED_FILE_PATH $userName $password $TIMEZONE
}



