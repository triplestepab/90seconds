# 90 Seconds

##

![7 second demo](animation.gif)

## Internal workflow

```mermaid
swimlane-beta LR

    subgraph play [Play phase]
        resetClock["Reset timer to 00:00"]
        incrementTimer["Increment timer"]
        reachedEnd{"2 seconds left (or less)"}
        saveVolume["Save the current volume"]
        fadeOut["Fadeout with the remaining time"]
    end

    subgraph gap [Gap phase]
        checkGap{"Is gap >0?"}
        runGapPhase["Send play/pause (will pause the player)"]
        resetGapClock["Reset timer to 00:00"]
        incrementGapTimer["Increment gap timer"]
        reachedGapEnd{"End of gap timer?"}
    end

    subgraph prepNext [Prep for next song]
        sendNextSongCommand["Play next song"]
        restoreVolume["Restore the volume to previous volume"]
    end

    resetClock --> incrementTimer
    incrementTimer --> reachedEnd
    reachedEnd -->|Yes| saveVolume
    reachedEnd -->|No| incrementTimer
    saveVolume --> fadeOut
    fadeOut --> checkGap
    checkGap -->|Yes| runGapPhase
    checkGap -->|No| sendNextSongCommand
    runGapPhase --> resetGapClock
    resetGapClock --> incrementGapTimer
    incrementGapTimer --> reachedGapEnd
    reachedGapEnd -->|Yes| sendNextSongCommand
    reachedGapEnd -->|No| incrementGapTimer
    sendNextSongCommand --> restoreVolume
    restoreVolume --> resetClock
```

## Debugging

Go to the application menu -> View -> "Enable debugging window"

```bash
# Deep dive logging
/usr/bin/log stream --level info --predicate 'process == "90 seconds"'
```

## Building

```bash
# Create the application inside the "Dist" folder
./build

# Internal use; creates a tag on main branch which in turn will produce a new release on github
./release.sh
```
