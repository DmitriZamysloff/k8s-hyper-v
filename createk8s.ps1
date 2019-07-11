#Requires -RunAsAdministrator
echo "+-------------------------------------+"
echo "|   K8S CLUSTER CREATOR FOR HYPER-V   |"
echo "+-------------------------------------+"
$SEED_FILE = "k8s-hyper-v.seed"
$temDir = $env:temp    
$MKISOFS_DIR_NAME = "MKISOFS_MD5_BIN"
$HOSTNAME = "vubuntu"

function Make-ISO ($WorkingDir, $ISOPrototypePath, $NewIsoPath) {
    $ZIP_FILE_NAME = "$($MKISOFS_DIR_NAME).zip"
    $ZIP_FILE = "$($WorkingDir)\$($ZIP_FILE_NAME)"

    if (!(Test-Path ($ZIP_FILE))) {
        Write-Host "Downloading Mkisofs"
        wget https://storage.googleapis.com/google-code-archive-downloads/v2/code.google.com/mkisofs-md5/mkisofs-md5-2.01-Binary.zip -OutFile "$($WorkingDir)\$($MKISOFS_DIR_NAME).zip"
    } else {
        Write-Host "Mkisofs archive found $($ZIP_FILE)"
    }
    Write-Host "Expanding Mkisofs archive $($ZIP_FILE)"
    Expand-Archive $ZIP_FILE -DestinationPath "$($WorkingDir)\$($MKISOFS_DIR_NAME)" -Force -ErrorAction Stop
    Start-Sleep -Seconds 5
    Write-Host "Starting Mkisofs for creation of ISO file $($NewIsoPath)"
    & "$($WorkingDir)\$($MKISOFS_DIR_NAME)\Binary\MinGW\Gcc-4.4.5\mkisofs.exe" -D -r -V "K8S_UBUNTU" -cache-inodes -J -l -b isolinux/isolinux.bin -c isolinux\boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -o $NewIsoPath $ISOPrototypePath
}

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
    while ("yes","no", "n", "y" -notcontains ($answer = Read-Host -Prompt $Prompt)) {
    }
    if ("yes" -eq $answer -or "y" -eq $answer) {
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
    [Boolean] $do_iso_download = !(Test-Path ($TargetIsoFile))
    if (!$do_iso_download) {
        $do_iso_download = Is-Yes-Response "ISO File $($TargetIsoFile) already exists. Download again? [yes|no]"
    }
    if ($do_iso_download -eq $true) {
        Download-Version $DownloadLocation $DownloadFile $TargetFolder
    }
    if (!(Test-Path ($TargetIsoFile))) {
        Write-Host "ERROR! Error downloading ISO file."
        exit
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
    if (Test-Path $Directory) {
        Write-Host "Removing old directory $($Directory)"
        Remove-Item -Recurse -Force $Directory -ErrorAction Stop
    }
}

function Create-New-Dir ($Directory) {
    Remove-Dir-If-Exists $Directory
    New-Item -ItemType "directory" $Directory -ErrorAction Stop
}

function Insert-Before ($FILE_PATH, $PATTERN, [String] $TO_INSERT) {
    #Write-Host "Tracing file $($FILE_PATH) for suitable positions"
    [System.Collections.ArrayList]$file = Get-Content $FILE_PATH
    $insert = @()

    for ($i = 0; $i -lt $file.Count; $i++) {
        if ($file[$i] -match $PATTERN) {
            $position = $i#$i-1
            $insert += $position #Recording the position
            #Write-Host "String at position $($i) ->[$($file[$i])]<- matched. Position $($position) added"
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

function Hash-File ($File) {
}

function Make-RW ([String] $FILE) {
    attrib -r $FILE
}

function Do-Remaster ($WORK_FOLDER, $ISO_IMAGE_PATH, $NEW_ISO_FILE, $NewIsoName, [String] $SEED_FILE_NAME, $SEED_FILE_PATH, [String] $USER_NAME, [String] $PASSWORD, [String] $TIME_ZONE, [String] $hostname) {
    
    $workFolder = "$($WORK_FOLDER)\iso_org"
    Write-Host "Remastering ISO File in $($workFolder)"
    
    Create-New-Dir $workFolder
    
    if (Test-Path ($NEW_ISO_FILE)) {
        Write-Host "Removing old remastered image $($NEW_ISO_FILE)"
        Remove-Item -Path $NEW_ISO_FILE
    }
    Write-Host "Mounting Disk Image $($ISO_IMAGE_PATH)"
    $mountResult = Mount-DiskImage -ImagePath $ISO_IMAGE_PATH -Access ReadOnly -PassThru -ErrorAction Stop
    $mountLetter = ($mountResult|Get-Volume).DriveLetter
    Write-Host "Awaiting proper mount"
    Start-Sleep -Seconds 5
    Write-Host "Disk Image $($ISO_IMAGE_PATH) is mounted to $($mountLetter)"
    try {
        Write-Host "Copying ISO content $($mountLetter):\* to $($workFolder)"
        Copy-Item "$($mountLetter):\*" -Destination $workFolder -Recurse -Force -ErrorAction Stop | Out-Null
    } finally {
        Write-Host "Dismounting Image"
        Dismount-DiskImage -ImagePath $ISO_IMAGE_PATH
    }
    Write-Host "Awaiting dismounting"
    Start-Sleep -Seconds 5
    Write-Host "Setting 'Normal' attributes for extracted files."
    Get-ChildItem $workFolder -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {!$_.PSIsContainer} | foreach {$_.Attributes = "Normal"} -ErrorAction Stop

    Write-Host "Setting new installation language to 'en'"

    Set-Content -Path $workFolder\isolinux\lang -Value "en'n" -ErrorAction Stop

    Write-Host "Setting timeout in $($workFolder)/isolinux/isolinux.cfg to 1"

    (Get-Content $workFolder\isolinux\isolinux.cfg) -replace "^timeout\s+([0-9]+)$","timeout 1" | Out-File $workFolder\isolinux\isolinux.cfg -ErrorAction Stop
    
    $lateCommand = "chroot /target curl -L /home/$($USER_NAME)/start.sh https://raw.githubusercontent.com/DmitriZamysloff/k8s-hyper-v/master/start.sh ; chroot /target chmod +x /home/$($USER_NAME)/start.sh ;"
    
    Write-Host "Copying seed file $($SEED_FILE_PATH) to $($workFolder)\preseed"
    Copy-Item $SEED_FILE_PATH -Destination $workFolder\preseed
    Write-Host "Setting up firstrun script"
    Echo "d-i preseed/late_command                              string $($lateCommand)" >> $workFolder\preseed\$SEED_FILE_NAME
    [String] $PASSWORD_HASH = Hash-PWD $PASSWORD
    (Get-Content $workFolder\preseed\$SEED_FILE_NAME) -replace "{{username}}","$($USER_NAME)" -replace "{{pwhash}}", $PASSWORD_HASH -replace "{{hostname}}", $hostname -replace "{{timezone}}",$TIME_ZONE | Out-File $workFolder\preseed\$SEED_FILE_NAME -ErrorAction Stop

    $SEED_CHECKSUM = Get-FileHash $workFolder\preseed\$SEED_FILE_NAME -Algorithm MD5
    $SEED_HASH = $SEED_CHECKSUM.Hash.toLower()

    Insert-Before $workFolder\isolinux\txt.cfg "^label install$" "label autoinstall`n  menu label ^Autoinstall V-K8S Ubuntu Server`n  kernel /install/vmlinuz`n  append file=/cdrom/preseed/ubuntu-server.seed initrd=/install/initrd.gz auto=true priority=high preseed/file=/cdrom/preseed/$($SEED_FILE_NAME) preseed/file/checksum=$($SEED_HASH)  /home/$($USER_NAME)/iso_new/preseed/$($SEED_FILE_NAME) --"

    Make-ISO $WORK_FOLDER $workFolder $ISO_IMAGE_PATH
}



$bL,$bV = Get-BionicLinkAndVersion
$DOWNLOAD_FILE = "ubuntu-$($bV)-server-amd64.iso"
$DOWNLOAD_LOCATION = "http://cdimage.ubuntu.com/releases/$($bL)release"
$NEW_ISO_NAME = "ubuntu-$($bV)-server-amd64-k8s.iso"

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

Write-Host "Downloading $($SEED_FILE)"
wget "https://raw.githubusercontent.com/DmitriZamysloff/k8s-hyper-v/master/$($SEED_FILE)" -OutFile $SEED_FILE_PATH

[Boolean] $do_remaster = ! (Test-Path ($NEW_ISO_FILE))

if (!($do_remaster)) {
    $do_remaster = Is-Yes-Response "Remastered File $($NEW_ISO_FILE) already exists. Do remastering again? [yes|no]"
} else {
    Write-Host "No remastered file found."
}
if ($do_remaster) {
    Do-Remaster $temDir $ISO_FILE $NEW_ISO_FILE $NEW_ISO_NAME $SEED_FILE $SEED_FILE_PATH $userName $password $TIMEZONE $HOSTNAME
    
}
Start-Sleep -Seconds 5
if (!(Test-Path ($NEW_ISO_FILE))) {
    Write-Host "ERROR! No ISO file $($NEW_ISO_FILE) created. Existing!" 
    return
}

Write-Host "--------\n finished remastering k8s ubuntu iso file\n the new file is located at: $($NEW_ISO_FILE)\n your user name is: $($userName)\n your password is: $($password)\n your hostname is: $($HOSTNAME)\n your timezone is: $($TIMEZONE)\n"


