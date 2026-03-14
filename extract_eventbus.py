import os

filepath = '/Users/john/Documents/GitHub/SwiftBot/SwiftBotApp/Models.swift'
with open(filepath, 'r') as f:
    lines = f.readlines()

start_idx = -1
end_idx = -1
for i, line in enumerate(lines):
    if '// MARK: - EventBus System' in line:
        start_idx = i
    if '// MARK: - Core Models' in line:
        end_idx = i
        break

if start_idx != -1 and end_idx != -1:
    eventbus_code = "import Foundation\n\n" + "".join(lines[start_idx:end_idx])
    
    # Ensure Models directory exists
    os.makedirs('/Users/john/Documents/GitHub/SwiftBot/SwiftBotApp/Models', exist_ok=True)
    
    with open('/Users/john/Documents/GitHub/SwiftBot/SwiftBotApp/Models/EventBus.swift', 'w') as f:
        f.write(eventbus_code)
    
    new_models = lines[:start_idx] + lines[end_idx:]
    with open(filepath, 'w') as f:
        f.writelines(new_models)
    print("Successfully extracted EventBus.swift")
else:
    print("Indices not found")
