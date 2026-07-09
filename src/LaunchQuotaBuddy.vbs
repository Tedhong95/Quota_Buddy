Option Explicit

Dim shell, fileSystem, scriptPath, language, command
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
shell.Run command, 0, False
