Option Explicit

Dim shell, fileSystem, scriptPath, language, command, wmi, processes, process, matcher
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptPath = fileSystem.BuildPath(fileSystem.GetParentFolderName(WScript.ScriptFullName), "QuotaBuddy.ps1")
language = "zh-CN"
If WScript.Arguments.Count > 0 Then language = WScript.Arguments(0)

command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & scriptPath & """ -Language " & language
If WScript.Arguments.Count > 1 Then
    If WScript.Arguments(1) = "--probe" Then
        WScript.Echo command
        WScript.Quit 0
    End If
    If WScript.Arguments(1) = "--delay" Then WScript.Sleep 750
End If

' Whichever launcher was used last owns the single running companion, even
' when the previous instance came from another folder or language edition.
On Error Resume Next
Set wmi = GetObject("winmgmts:\\.\root\cimv2")
Set processes = wmi.ExecQuery("SELECT * FROM Win32_Process WHERE Name='powershell.exe' OR Name='pwsh.exe'")
Set matcher = New RegExp
matcher.IgnoreCase = True
matcher.Pattern = "-File\s+(""[^""]*QuotaBuddy\.ps1""|[^\s]*QuotaBuddy\.ps1)(\s|$)"
For Each process In processes
    If matcher.Test(process.CommandLine) Then process.Terminate
Next
On Error GoTo 0
WScript.Sleep 300
shell.Run command, 0, False
