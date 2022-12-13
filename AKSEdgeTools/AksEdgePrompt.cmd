@echo off
powershell -Command "Start-Process 'powershell.exe' -ArgumentList '-noexit -ExecutionPolicy Bypass -File \"%~dp0\AksEdgeShell.ps1\"' -Verb runAs"
