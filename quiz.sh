#!/usr/bin/env bash

QUIZ_FILE="musicquiz.csv"
HIGHSCORE_FILE="highscore.csv"
INTRO_DURATION=25
DEFAULT_START_TIME=10
CACHE_DIR="/tmp/musicquiz_cache"
COUNTDOWN_SECONDS=3
TIME_ENTITY_SPECIFIER="%s%N"
TIME_ENTITY_STR="nanoseconds"
TIME_ENTITY_IN_S=1000000000
SCORE_REDUCER=1000000
DEP_CSVPEEK_RS="csvpeek-rs"
DEP_MPV="mpv"
DEP_COLUMN="column"
DEP_YTDLP="yt-dlp"
DEP_FIGLET="figlet"
DEP_TPUT="tput"

check_dependency() {
    command -v "$1" >/dev/null 2>&1 || {
        echo >&2 "Error: '$1' is not installed or not in your PATH. Please install it and try again."
        exit 1
    }
}

check_dependency "$DEP_CSVPEEK_RS"
check_dependency "$DEP_MPV"
check_dependency "$DEP_COLUMN"
check_dependency "$DEP_YTDLP"
check_dependency "$DEP_FIGLET"
check_dependency "$DEP_TPUT"

show_highscore() {
    echo ""
    echo "--- CURRENT HIGHSCORES ---"
    local expected_header="Player,Points"

    if [ ! -f "$HIGHSCORE_FILE" ]; then
        echo "No highscore list exists yet. Be the first to play!"
        echo "$expected_header" > "$HIGHSCORE_FILE"
    elif [ ! -s "$HIGHSCORE_FILE" ]; then
        echo "Highscore file was empty. Initializing with header."
        echo "$expected_header" > "$HIGHSCORE_FILE"
    elif ! head -n 1 "$HIGHSCORE_FILE" | grep -qF "$expected_header"; then
        echo "Warning: The highscore file's header ('$(head -n 1 "$HIGHSCORE_FILE")') does not match expected ('$expected_header')."
        echo "Attempting to proceed, but column selection might fail."
    fi

    local sorted_data=""
    local low_score=""

    local all_points_values
    all_points_values=$("$DEP_CSVPEEK_RS" -f "$HIGHSCORE_FILE" --list -c "Points" --raw 2>/dev/null)

    if [ -n "$all_points_values" ]; then
        local top_10_score_lines
        top_10_score_lines=$(echo "$all_points_values" | grep '^[0-9]\+$' | sort -n -r | head -n 10)

        if [ -n "$top_10_score_lines" ]; then
            low_score=$(echo "$top_10_score_lines" | tail -n 1)
        fi
    fi

    if [ -n "$low_score" ]; then
        local candidates_tab_data
        candidates_tab_data=$("$DEP_CSVPEEK_RS" --list -f "$HIGHSCORE_FILE" -c "Player,Points" --filter "Points>=$low_score" --raw 2>/dev/null)

        if [ -n "$candidates_tab_data" ]; then
            local sorted_tab_data
            sorted_tab_data=$(echo "$candidates_tab_data" | LC_ALL=C sort -t$'\t' -k2,2nr | head -n 10)

            if [ -n "$sorted_tab_data" ]; then
                sorted_data=$(echo "$sorted_tab_data" | tr '\t' ',')
            fi
        fi
    fi

    if [ -z "$sorted_data" ]; then
        echo "No highscores to display."
        (echo "$expected_header") | "$DEP_COLUMN" -t -s ','
    else
        (echo "$expected_header" && echo "$sorted_data") | "$DEP_COLUMN" -t -s ','
    fi
    echo "--------------------------"
    echo ""
}

cleanup_cache() {
    if [ -d "$CACHE_DIR" ]; then
        echo "Cleaning up temporary audio files in $CACHE_DIR..."
        rm -rf "$CACHE_DIR"
        echo "Cleanup complete."
    fi
}

trap cleanup_cache EXIT

countdown_display() {
    local q_count="$1"
    local total_q="$2"
    local term_cols=$("$DEP_TPUT" cols)
    local figlet_font="banner"

    for (( i=COUNTDOWN_SECONDS; i>0; i-- )); do
        clear
        echo "--- QUESTION $q_count of $total_q ---"
        echo ""
        echo "Get ready!"
        echo ""
        
        local figlet_output=$(echo "$i" | "$DEP_FIGLET" -f "$figlet_font")
        local figlet_width=$(echo "$figlet_output" | awk '{ if (length > max_len) max_len = length } END { print max_len }')
        local padding=$(( (term_cols - figlet_width) / 2 ))
        if [ "$padding" -lt 0 ]; then padding=0; fi

        echo "$figlet_output" | while IFS= read -r line; do
            printf "%*s%s\n" "$padding" "" "$line"
        done

        echo ""
        sleep 1
    done
    clear
}

echo "Welcome to Guess the Song – Ultimate Intro Challenge!"

read -p "Enter your name: " player_name
if [ -z "$player_name" ]; then
    player_name="Anonymous Player"
    echo "No name entered, you will play as '$player_name'."
fi

show_highscore

all_questions_raw=$("$DEP_CSVPEEK_RS" --list -f "$QUIZ_FILE" -c "Artist,Title,YouTubeLink,Option1,Option2,Option3,Option4,Option5" --raw)

if [ -z "$all_questions_raw" ]; then
    echo "Error: The quiz file '$QUIZ_FILE' is empty or invalid. Please add some questions."
    exit 1
fi

max_available_questions=$(echo "$all_questions_raw" | wc -l | tr -d ' ')
if [ "$max_available_questions" -eq 0 ]; then
    echo "Error: No questions found in '$QUIZ_FILE'. Please ensure it contains data rows."
    exit 1
fi

read -p "Hello $player_name! There are $max_available_questions unique questions available. How many questions would you like to play in this quiz? " num_questions

if ! [[ "$num_questions" =~ ^[0-9]+$ ]] || [ "$num_questions" -eq 0 ]; then
    echo "Invalid number of questions. Playing 5 questions."
    num_questions=5
elif [ "$num_questions" -gt "$max_available_questions" ]; then
    echo "You requested $num_questions questions, but only $max_available_questions are available. Playing all $max_available_questions questions."
    num_questions="$max_available_questions"
fi

mapfile -t quiz_questions_array < <(echo "$all_questions_raw" | tr -d '\r' | shuf | head -n "$num_questions")

echo ""
echo "Pre-buffering quiz intros. This might take a moment..."
mkdir -p "$CACHE_DIR"

declare -A cached_files

for i in "${!quiz_questions_array[@]}"; do
    question_data="${quiz_questions_array[$i]}"
    IFS=$'\t' read -r artist title youtube_link_full option1 option2 option3 option4 option5 rest_of_options <<< "$question_data"

    extracted_start_time="$DEFAULT_START_TIME"
    
    if [[ "$youtube_link_full" =~ [?\&]t=([0-9]+) ]]; then
        extracted_start_time="${BASH_REMATCH[1]}"
    fi

    youtube_link_base=$(echo "$youtube_link_full" | sed 's/[?&]t=[0-9]*//')
    sanitized_link=$(echo "$youtube_link_base" | sed 's/[^a-zA-Z0-9_\-]/_/g')
    output_filename="${CACHE_DIR}/quiz_intro_${i}_${sanitized_link}_${extracted_start_time}-${INTRO_DURATION}s.mp3"

    if [ ! -f "$output_filename" ]; then
        echo "Downloading intro for question $((i+1))/$num_questions..."
        "$DEP_YTDLP" \
            -x --audio-format mp3 \
            --postprocessor-args "-ss $extracted_start_time -t $INTRO_DURATION" \
            -o "$output_filename" \
            "$youtube_link_base" \
            --quiet --no-warnings --no-progress \
            >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "Warning: Failed to download intro for '$youtube_link_full'. This question might be skipped or cause issues."
        fi
    else
        echo "Intro for question $((i+1))/$num_questions already cached."
    fi
    cached_files["$youtube_link_full"]="$output_filename"
done

echo "Pre-buffering complete! Starting quiz."
echo ""

total_score=0
current_question_count=0

echo ""
echo "--- QUIZ STARTING NOW! ---"
echo "Prepare to listen carefully and answer quickly!"
echo ""

for question_data in "${quiz_questions_array[@]}"; do
    ((current_question_count++))
    IFS=$'\t' read -r artist title youtube_link_full option1 option2 option3 option4 option5 rest_of_options <<< "$question_data"
    options_array=("$option1" "$option2" "$option3" "$option4" "$option5")
    correct_answer="$title"
    shuffled_options=()
    mapfile -t shuffled_options < <(printf "%s\n" "${options_array[@]}" | shuf)

    countdown_display "$current_question_count" "$num_questions"

    echo "--- QUESTION $current_question_count of $num_questions ---"
    echo ""
    echo "What song is this?"

    for i in "${!shuffled_options[@]}"; do
        echo "$((i+1)). ${shuffled_options[i]}"
    done

    echo "Playing intro..."
    local_audio_file="${cached_files["$youtube_link_full"]}"

    if [ -f "$local_audio_file" ]; then
        "$DEP_MPV" --no-video --no-config "$local_audio_file" 2&>/dev/null &
        MPV_PID=$!
    else
        echo "Error: Cached file not found for this question. Skipping audio playback."
        MPV_PID=0
    fi

    start_time=$(date +$TIME_ENTITY_SPECIFIER)
    read -p "Your answer (enter the number, e.g., 1): " user_choice

    if [ "$MPV_PID" -ne 0 ]; then
        kill "$MPV_PID" 2>/dev/null
    fi
    end_time=$(date +$TIME_ENTITY_SPECIFIER)
    response_time=$((end_time - start_time))

    num_shuffled_options=${#shuffled_options[@]}
    if ! [[ "$user_choice" =~ ^[0-9]+$ ]] || [ "$user_choice" -lt 1 ] || [ "$user_choice" -gt "$num_shuffled_options" ]; then
        echo "Invalid choice. Please enter a number between 1 and $num_shuffled_options."
        echo "The correct answer was: '$correct_answer'."
        echo "You answered in $response_time $TIME_ENTITY_STR."
        echo ""
        continue
    fi

    selected_option="${shuffled_options[$((user_choice-1))]}"
    current_question_points=0

    if [ "$selected_option" == "$correct_answer" ]; then
        intro_duration_ns=$((INTRO_DURATION * TIME_ENTITY_IN_S))
        time_saved_ns=$((intro_duration_ns - response_time))
        
        calculated_points=$TIME_ENTITY_IN_S # Default minimum points for a correct answer if answered very slow / time_saved_ns is not positive

        if (( time_saved_ns > 0 )); then
            calculated_points=$time_saved_ns # Base for >15s, effectively time_saved_ns * 1
            if (( response_time <= 5 * TIME_ENTITY_IN_S )); then
                calculated_points=$((time_saved_ns * 5))
            elif (( response_time <= 10 * TIME_ENTITY_IN_S )); then
                calculated_points=$((time_saved_ns * 3))
            elif (( response_time <= 15 * TIME_ENTITY_IN_S )); then
                calculated_points=$((time_saved_ns * 2))
            fi
        fi
        
        current_question_points=$((calculated_points/SCORE_REDUCER))
        if (( current_question_points <= 0 )); then # Ensure minimum 1 point if logic resulted in 0 or less
             current_question_points=1
        fi

        echo "CONGRATULATIONS! Correct answer in $response_time $TIME_ENTITY_STR! You earned $current_question_points points."
        ((total_score+=current_question_points))
    else
        echo "Sorry, that was incorrect. The correct answer was: '$correct_answer'."
        echo "You answered in $response_time $TIME_ENTITY_STR."
    fi
    echo ""
    sleep 2.5
done

echo "--- QUIZ COMPLETED ---"
echo "$player_name, you scored a total of $total_score points out of $current_question_count questions!"
echo "$player_name,$total_score" >> "$HIGHSCORE_FILE"
echo "Your result has been saved to the highscore list."

show_highscore

echo "Thank you for playing!"
