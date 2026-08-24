# StrictMode shape gate.
#
# Finds every function whose multiple `return @{...}` literals disagree on keys, then
# flags only callers that dot-read a key missing from some path - the exact class that
# broke ImportPxeBootWim (2026-08-24: .packaged only existed on the non-early-return
# paths, so re-importing an existing boot WIM crashed). Nested scriptblock returns and
# argument hashtables are excluded; exits 1 on any hit.
#
# Run: pwsh -NoProfile -File scripts/test-strictmode-shapes.ps1
param([string]$Root = (Join-Path $PSScriptRoot '../sidecar'))
$producers=@{}   # fn name -> @{ union=..; every=.. }
$files = Get-ChildItem $Root -Recurse -Filter *.ps1 -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch 'node_modules|vendor/psmodules|site-build-scripts' }
$asts=@{}
foreach($f in $files){
    $e=$null;$tk=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tk,[ref]$e)
    if($e){continue}
    $asts[$f.FullName]=$ast
    foreach($fn in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)){
        $sets=@()
        foreach($r in $fn.FindAll({param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst]},$true)){
            # Only returns whose NEAREST enclosing function is THIS one - a nested
            # scriptblock (child-process runner, callback) has its own contract.
            $anc=$r.Parent; $owner=$null
            while($anc){
                if($anc -is [System.Management.Automation.Language.FunctionDefinitionAst]){ $owner=$anc; break }
                # A scriptblock literal between the return and the function is its own
                # contract (child-process runner, callback) - not this function's return.
                if(($anc -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) -and ($anc.Parent -isnot [System.Management.Automation.Language.FunctionDefinitionAst])){ $owner=$null; break }
                $anc=$anc.Parent
            }
            if($owner -ne $fn){ continue }
            if(-not $r.Pipeline){continue}
            $h=$r.Pipeline.Find({param($n) $n -is [System.Management.Automation.Language.HashtableAst]},$true)
            if(-not $h){continue}
            # An argument hashtable (return New-Foo -Arg @{..}) is not this function's shape.
            $up=$h.Parent; $isArg=$false
            while($up -and $up -ne $r){ if($up -is [System.Management.Automation.Language.CommandAst]){$isArg=$true;break}; $up=$up.Parent }
            if($isArg){continue}
            $sets += ,@($h.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text.Trim("'",'"') })
        }
        if($sets.Count -lt 2){continue}
        $union=@($sets | ForEach-Object { $_ } | Sort-Object -Unique)
        $every=@($union | Where-Object { $k=$_; @($sets | Where-Object { $_ -notcontains $k }).Count -eq 0 })
        if(@($union | Where-Object { $every -notcontains $_ }).Count -gt 0){
            $producers[$fn.Name]=@{ union=$union; every=$every }
        }
    }
}
$hits=0
foreach($fp in $asts.Keys){
    $ast=$asts[$fp]
    foreach($fn in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)){
        # var -> producer, from "$x = Producer ..." assignments in this function
        $vars=@{}
        foreach($as in $fn.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst]},$true)){
            if($as.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]){continue}
            $cmd=$as.Right.Find({param($n) $n -is [System.Management.Automation.Language.CommandAst]},$true)
            if(-not $cmd){continue}
            $name=$cmd.GetCommandName()
            if($name -and $producers.ContainsKey($name)){ $vars[$as.Left.VariablePath.UserPath]=$name }
        }
        if($vars.Count -eq 0){continue}
        foreach($me in $fn.FindAll({param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst]},$true)){
            if($me.Expression -isnot [System.Management.Automation.Language.VariableExpressionAst]){continue}
            $v=$me.Expression.VariablePath.UserPath
            if(-not $vars.ContainsKey($v)){continue}
            $key=$me.Member.Extent.Text
            $p=$producers[$vars[$v]]
            if(($p.union -contains $key) -and ($p.every -notcontains $key)){
                $hits++
                Write-Host ("  {0}:{1}  `${2}.{3}  <- {4} only returns '{3}' on some paths" -f `
                    ($fp -replace [regex]::Escape("$Root/"),''), $me.Extent.StartLineNumber, $v, $key, $vars[$v])
            }
        }
    }
}
if($hits -eq 0){ Write-Host "strictmode shapes: all checks passed" } else { Write-Host "strictmode shapes: $hits risky read(s)"; exit 1 }
