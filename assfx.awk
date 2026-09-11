#!/usr/bin/gawk -E

BEGINFILE {
    first_section = 0
    comments = ""
}

# 1. 删除无效的 Script Type 行
/^Script Type: V4\.00\+/ {
    next
}

# 2. 遇到第一个节标题（如 [Script Info]）
!first_section && /^\[.*\]/ {
    print $0
    if (comments != "") {
        printf "%s", comments
    }
    first_section = 1
    next
}

# 3. 在第一个节标题之前，收集以 ; 开头的注释行
!first_section && /^;/ {
    comments = comments $0 "\n"
    next
}

# 4. 处理其他所有行
{
    line = $0

    # 4a. 将对话行中的 *Default 样式修正为 Default（只在事件行中操作）
    if (line ~ /^(Dialogue|Comment):/) {
        gsub(/, *\*Default,/, ",Default,", line)
    }

    # 4b. 将 \fade(任意数字,任意数字) 修正为 \fad(...)
    line = gensub(/\\fade\(([0-9.]+),([0-9.]+)\)/, "\\fad(\\1,\\2)", "g", line)

    # 4c. 将 [Events] 头部的 Actor 字段名统一为 Name（仅在格式行中操作）
    if (line ~ /^Format:/ && line ~ /Actor/) {
        gsub(/Actor/, "Name", line)
    }

    # 4d. 若为对话行且开始时间等于结束时间，则转为注释行
    if (line ~ /^(Dialogue|Comment):/) {
        # 使用正则提取 Start 和 End（第一个逗号后的两个时间）
        if (match(line, /^[^:]+:[[:space:]]*[^,]*,[[:space:]]*([^,]*)[[:space:]]*,[[:space:]]*([^,]*)/, arr)) {
            start = arr[1]
            end   = arr[2]
            # 去除首尾空白（如果有）
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", start)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", end)
            if (start == end) {
                sub(/^Dialogue:/, "Comment:", line)
            }
        }
    }

    print line
}
