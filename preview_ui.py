#!/usr/bin/env python3
"""
================================================================================
  ROS ikhozzzz v2.6.0 - In-Game UI & Overlay Simulator (macOS Preview)
  Author: ikhozzzz & Google Antigravity Agent
  Simulates the complete iOS Game Screen, Mod Menu, Real-time Bot/Player Counter,
  Memory Engine Logs, and ESP/Fly visuals in pure Python Tkinter (Zero pip dependencies).
================================================================================
"""

import os
import sys
import time
import math
import random
import tkinter as tk
from tkinter import font

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUNDLE_DIR = os.path.join(SCRIPT_DIR, "new-version", "IPA_Direct_Injection", "D79oM.bundle")
if not os.path.exists(BUNDLE_DIR):
    BUNDLE_DIR = os.path.join(SCRIPT_DIR, "IPA_Direct_Injection", "D79oM.bundle")

HEADER_IMG_PATH = os.path.join(BUNDLE_DIR, "header.png")
BACK_IMG_PATH = os.path.join(BUNDLE_DIR, "back.png")


class ModernSwitch(tk.Canvas):
    """iOS-style smooth toggle switch widget"""
    def __init__(self, parent, width=50, height=26, initial=False, command=None, bg="#1a1c23"):
        super().__init__(parent, width=width, height=height, bg=bg, highlightthickness=0, bd=0)
        self.width = width
        self.height = height
        self.state = initial
        self.command = command
        self.pill_bg = bg
        
        self.r = height // 2
        self.thumb_x = width - self.r if initial else self.r
        self.target_x = self.thumb_x
        
        self.bind("<Button-1>", self.toggle)
        self.draw()

    def toggle(self, event=None):
        self.set_state(not self.state)
        if self.command:
            self.command(self.state)

    def set_state(self, new_state):
        self.state = new_state
        self.target_x = self.width - self.r if self.state else self.r
        self.animate()

    def animate(self):
        step = 3
        if abs(self.thumb_x - self.target_x) > 2:
            if self.thumb_x < self.target_x:
                self.thumb_x += step
            else:
                self.thumb_x -= step
            self.draw()
            self.after(16, self.animate)
        else:
            self.thumb_x = self.target_x
            self.draw()

    def draw(self):
        self.delete("all")
        # Track background
        track_color = "#34C759" if self.state else "#3A3F4E"
        # Draw rounded rectangle (2 arcs + 1 rect)
        self.create_arc(0, 0, self.height, self.height, start=90, extent=180, fill=track_color, outline=track_color)
        self.create_arc(self.width - self.height, 0, self.width, self.height, start=270, extent=180, fill=track_color, outline=track_color)
        self.create_rectangle(self.r, 0, self.width - self.r, self.height, fill=track_color, outline=track_color)
        
        # Draw thumb
        thumb_r = self.r - 2
        self.create_oval(self.thumb_x - thumb_r, 2, self.thumb_x + thumb_r, self.height - 2, fill="#FFFFFF", outline="#E5E5EA")


class GameScreenPreview(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Rules of Survival - [ROS ikhozzzz v2.6.0 VIP Yes 360] Game Overlay Simulator")
        self.geometry("1120x680")
        self.minsize(960, 580)
        self.configure(bg="#0B0D13")
        
        # Feature States
        self.features = {
            "WALLHACK": False,
            "NO RECOIL 100%": False,
            "AIMLOCK 100%": False,
            "NO RECOIL": False,
            "SPEED": False,
            "SPEED EPIC": False,
            "1 HIT": False,
            "HIGH SCOPE": False,
            "FASH SHOOT": False,
            "AUTO SCOPE": False,
            "AIMBOT 360": False,
            "AIMBOT 180": False,
            "ESP LINE": True,   # Default ON for demo
            "FLY": False,
            "BOT MATCH TEST": True
        }
        
        # Player and Bot Count Simulation
        self.real_players = 16
        self.bot_players = 44
        self.total_players = 60
        self.altitude = 0.0
        
        # Simulated Targets for ESP
        self.targets = [
            {"x": 320, "y": 340, "dist": 68, "is_bot": True, "name": "Bot_Alpha", "hp": 100},
            {"x": 680, "y": 290, "dist": 142, "is_bot": False, "name": "ProSniper99", "hp": 85},
            {"x": 480, "y": 380, "dist": 28, "is_bot": False, "name": "Vibol_Player", "hp": 100},
            {"x": 810, "y": 360, "dist": 95, "is_bot": True, "name": "Bot_Charlie", "hp": 40},
            {"x": 190, "y": 310, "dist": 180, "is_bot": True, "name": "Bot_Delta", "hp": 100},
        ]
        
        # Setup UI
        self.setup_game_canvas()
        self.setup_terminal_log_hud()
        self.setup_counter_hud()
        self.setup_mod_menu_window()
        self.setup_floating_icon()
        
        # Start game tick loops
        self.after(100, self.game_loop)
        self.after(3000, self.simulate_match_changes)
        
        self.log_message("SYSTEM", "Rules of Survival Client v2.4.0 (arm64) Initialized")
        self.log_message("MOD", "ROS ikhozzzz dylib injected successfully via D79oM hook")
        self.log_message("HUD", "Real-Time Player & Bot Counter HUD initialized")

    # =========================================================================
    # 1. GAME CANVAS & SIMULATED 3D BATTLEFIELD
    # =========================================================================
    def setup_game_canvas(self):
        self.canvas = tk.Canvas(self, bg="#0e131d", highlightthickness=0)
        self.canvas.pack(fill=tk.BOTH, expand=True)
        self.canvas.bind("<Configure>", lambda e: self.redraw_game_world())

    def redraw_game_world(self):
        w = self.canvas.winfo_width()
        h = self.canvas.winfo_height()
        if w < 100 or h < 100:
            return
            
        self.canvas.delete("game_bg")
        self.canvas.delete("game_hud")
        self.canvas.delete("esp")
        
        horizon = int(h * 0.45 + self.altitude * 1.5)
        
        # Sky Gradient / Dark Sunset Battlefield
        self.canvas.create_rectangle(0, 0, w, horizon, fill="#121826", outline="", tags="game_bg")
        self.canvas.create_rectangle(0, horizon, w, h, fill="#1c241a", outline="", tags="game_bg")
        
        # Terrain grid lines / perspective ground
        for y_offset in range(horizon, h, 28):
            self.canvas.create_line(0, y_offset, w, y_offset, fill="#232f20", tags="game_bg")
        
        # Perspective road/lines
        cx = w // 2
        self.canvas.create_line(cx - 30, horizon, 0, h, fill="#2d3b2a", width=2, tags="game_bg")
        self.canvas.create_line(cx + 30, horizon, w, h, fill="#2d3b2a", width=2, tags="game_bg")
        
        # Mountain silhouettes in background
        mountains = [
            (0, horizon), (w * 0.15, horizon - 50), (w * 0.35, horizon - 20),
            (w * 0.55, horizon - 70), (w * 0.75, horizon - 30), (w, horizon)
        ]
        self.canvas.create_polygon(mountains, fill="#161e2e", tags="game_bg")
        
        # Crosshair in center
        ch_size = 14
        cy = h // 2
        # If High Scope is on, draw scope circle
        if self.features["HIGH SCOPE"]:
            self.canvas.create_oval(cx - 160, cy - 160, cx + 160, cy + 160, outline="#00FFCC", width=3, tags="game_hud")
            self.canvas.create_line(cx - 160, cy, cx + 160, cy, fill="#00FFCC", width=1, dash=(4, 4), tags="game_hud")
            self.canvas.create_line(cx, cy - 160, cx, cy + 160, fill="#00FFCC", width=1, dash=(4, 4), tags="game_hud")
            self.canvas.create_text(cx, cy - 175, text="8x OPTICAL SNIPER SCOPE", fill="#00FFCC", font=("Arial", 11, "bold"), tags="game_hud")
        else:
            self.canvas.create_line(cx - ch_size, cy, cx - 4, cy, fill="#FFFFFF", width=2, tags="game_hud")
            self.canvas.create_line(cx + 4, cy, cx + ch_size, cy, fill="#FFFFFF", width=2, tags="game_hud")
            self.canvas.create_line(cx, cy - ch_size, cx, cy - 4, fill="#FFFFFF", width=2, tags="game_hud")
            self.canvas.create_line(cx, cy + 4, cx, cy + ch_size, fill="#FFFFFF", width=2, tags="game_hud")
            self.canvas.create_oval(cx - 2, cy - 2, cx + 2, cy + 2, fill="#FF3B30", outline="", tags="game_hud")

        # In-game Top Compass Bar
        compass_w = 420
        self.canvas.create_rectangle(cx - compass_w//2, 12, cx + compass_w//2, 38, fill="#000000", outline="#3A3F4E", width=1, tags="game_hud")
        for deg, txt in [(0, "N"), (45, "NE"), (90, "E"), (135, "SE"), (180, "S"), (225, "SW"), (270, "W"), (315, "NW")]:
            offset = ((deg - 75) % 360 - 180) * 1.8
            tx = cx + offset
            if cx - compass_w//2 + 20 < tx < cx + compass_w//2 - 20:
                self.canvas.create_text(tx, 25, text=txt, fill="#00FFCC" if txt in ["N","S","E","W"] else "#AAAAAA", font=("Arial", 10, "bold"), tags="game_hud")

        # In-game Mini-Map (Top Right)
        mm_x = w - 120
        mm_y = 75
        self.canvas.create_oval(mm_x - 55, mm_y - 55, mm_x + 55, mm_y + 55, fill="#121820", outline="#FFCC00", width=2, tags="game_hud")
        self.canvas.create_line(mm_x, mm_y - 55, mm_x, mm_y + 55, fill="#2A3545", tags="game_hud")
        self.canvas.create_line(mm_x - 55, mm_y, mm_x + 55, mm_y, fill="#2A3545", tags="game_hud")
        self.canvas.create_polygon([mm_x, mm_y - 8, mm_x - 6, mm_y + 6, mm_x + 6, mm_y + 6], fill="#00FFCC", tags="game_hud")
        self.canvas.create_text(mm_x, mm_y + 65, text="SAFE ZONE 01:42", fill="#FFCC00", font=("Arial", 9, "bold"), tags="game_hud")

        # In-game Weapon & Health Bar (Bottom Left)
        self.canvas.create_rectangle(30, h - 70, 260, h - 25, fill="#161B26", outline="#303A4D", width=1, tags="game_hud")
        # Health green bar
        self.canvas.create_rectangle(35, h - 65, 235, h - 50, fill="#34C759", outline="", tags="game_hud")
        self.canvas.create_text(135, h - 57, text="HP  100 / 100", fill="#FFFFFF", font=("Arial", 10, "bold"), tags="game_hud")
        # Ammo
        ammo_txt = "M4A1  30 / 180" if not self.features["FASH SHOOT"] else "M4A1  [FAST BURST 999]"
        self.canvas.create_text(95, h - 37, text=ammo_txt, fill="#FFCC00", font=("Arial", 10, "bold"), tags="game_hud")

        # Render 3D Targets & ESP Overlays
        self.draw_targets_and_esp(cx, cy, horizon)

    def draw_targets_and_esp(self, cx, cy, horizon):
        for t in self.targets:
            tx = t["x"]
            ty = t["y"] + int(self.altitude)
            
            # Draw Character Silhouette
            char_h = int(60 * (150 / (t["dist"] + 40)))
            char_w = int(char_h * 0.45)
            
            color = "#FF3B30" if not t["is_bot"] else "#FF9500"
            
            # Wallhack box
            if self.features["WALLHACK"] or self.features["ESP LINE"]:
                # 2D Bounding Box
                self.canvas.create_rectangle(
                    tx - char_w//2, ty - char_h, tx + char_w//2, ty,
                    outline=color, width=2, tags="esp"
                )
                # Corner accents
                corner_len = 6
                self.canvas.create_line(tx - char_w//2, ty - char_h, tx - char_w//2 + corner_len, ty - char_h, fill="#00FFCC", width=2, tags="esp")
                self.canvas.create_line(tx - char_w//2, ty - char_h, tx - char_w//2, ty - char_h + corner_len, fill="#00FFCC", width=2, tags="esp")
                
                # Tag text: [Real] or [Bot] + Distance + HP
                badge = f"🟢 REAL {t['name']}" if not t["is_bot"] else f"🤖 BOT {t['name']}"
                tag_str = f"{badge} [{t['dist']}m]"
                self.canvas.create_rectangle(tx - 65, ty - char_h - 22, tx + 65, ty - char_h - 4, fill="#000000", outline=color, tags="esp")
                self.canvas.create_text(tx, ty - char_h - 13, text=tag_str, fill="#FFFFFF", font=("Arial", 9, "bold"), tags="esp")
                
                # Mini HP bar
                hp_w = 40
                self.canvas.create_rectangle(tx - hp_w//2, ty - char_h - 3, tx + hp_w//2, ty - char_h, fill="#444444", tags="esp")
                self.canvas.create_rectangle(tx - hp_w//2, ty - char_h - 3, tx - hp_w//2 + int(hp_w * (t["hp"]/100)), ty - char_h, fill="#34C759", tags="esp")

            # ESP LINE (Antenna Line from player / sky to target)
            if self.features["ESP LINE"]:
                # Sky Line (Antenna beam straight up to the sky)
                self.canvas.create_line(tx, ty - char_h, tx, 0, fill=color, width=1.5, dash=(6, 2), tags="esp")
                # Tracer line from bottom screen center to enemy foot
                h = self.canvas.winfo_height()
                self.canvas.create_line(cx, h - 20, tx, ty, fill=color, width=1, dash=(2, 3), tags="esp")

            # AIMBOT 360 / 180 Target lock ring
            if (self.features["AIMBOT 360"] or self.features["AIMBOT 180"]) and t["dist"] < 80:
                self.canvas.create_oval(tx - 24, ty - char_h//2 - 24, tx + 24, ty - char_h//2 + 24, outline="#FF0055", width=2, tags="esp")
                self.canvas.create_text(tx, ty + 15, text=">>> LOCKED (YES 360) <<<", fill="#FF0055", font=("Arial", 8, "bold"), tags="esp")

    # =========================================================================
    # 2. DRAGGABLE REAL-TIME PLAYER & BOT COUNTER HUD
    # =========================================================================
    def setup_counter_hud(self):
        self.hud_frame = tk.Frame(self, bg="#0E121B", bd=2, relief=tk.RAISED, highlightbackground="#00FFCC", highlightthickness=1)
        self.hud_frame.place(x=320, y=55)
        
        # Drag handles
        self.hud_frame.bind("<Button-1>", self.on_hud_drag_start)
        self.hud_frame.bind("<B1-Motion>", self.on_hud_drag_motion)
        
        self.lbl_title = tk.Label(
            self.hud_frame, text="⚡ ROS ikhozzzz RADAR", bg="#0E121B", fg="#8E9BB0", font=("Arial", 9, "bold")
        )
        self.lbl_title.pack(side=tk.LEFT, padx=(10, 8), pady=6)
        self.lbl_title.bind("<Button-1>", self.on_hud_drag_start)
        self.lbl_title.bind("<B1-Motion>", self.on_hud_drag_motion)
        
        # Real Players Badge
        self.lbl_real = tk.Label(
            self.hud_frame, text=f"🟢 Real: {self.real_players}", bg="#14261C", fg="#34C759", font=("Arial", 11, "bold"), padx=8, pady=3
        )
        self.lbl_real.pack(side=tk.LEFT, padx=4, pady=4)
        
        # Bot Players Badge
        self.lbl_bot = tk.Label(
            self.hud_frame, text=f"🤖 Bots: {self.bot_players}", bg="#2B1E14", fg="#FF9500", font=("Arial", 11, "bold"), padx=8, pady=3
        )
        self.lbl_bot.pack(side=tk.LEFT, padx=4, pady=4)
        
        # Total Alive Badge
        self.lbl_total = tk.Label(
            self.hud_frame, text=f"[Total: {self.total_players}]", bg="#19202E", fg="#00FFCC", font=("Arial", 11, "bold"), padx=8, pady=3
        )
        self.lbl_total.pack(side=tk.LEFT, padx=(4, 10), pady=4)

    def on_hud_drag_start(self, event):
        self._hud_drag_x = event.x
        self._hud_drag_y = event.y

    def on_hud_drag_motion(self, event):
        x = self.hud_frame.winfo_x() - self._hud_drag_x + event.x
        y = self.hud_frame.winfo_y() - self._hud_drag_y + event.y
        self.hud_frame.place(x=x, y=y)

    def update_counter_labels(self):
        self.lbl_real.config(text=f"🟢 Real: {self.real_players}")
        self.lbl_bot.config(text=f"🤖 Bots: {self.bot_players}")
        self.lbl_total.config(text=f"[Total: {self.total_players}]")

    # =========================================================================
    # 3. TERMINAL LOG HUD (Simulates live memory scanner & engine hooks)
    # =========================================================================
    def setup_terminal_log_hud(self):
        self.term_frame = tk.Frame(self, bg="#0A0D14", bd=1, relief=tk.SOLID, highlightbackground="#1F2937", highlightthickness=1)
        self.term_frame.place(x=20, y=75, width=280, height=220)
        
        term_header = tk.Frame(self.term_frame, bg="#111827", height=24)
        term_header.pack(fill=tk.X)
        tk.Label(term_header, text="● DEBUG CONSOLE", bg="#111827", fg="#10B981", font=("Courier", 9, "bold")).pack(side=tk.LEFT, padx=6)
        
        self.term_text = tk.Text(self.term_frame, bg="#05070B", fg="#10B981", font=("Courier", 8), bd=0, highlightthickness=0)
        self.term_text.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)
        self.term_text.tag_config("SYSTEM", foreground="#3B82F6")
        self.term_text.tag_config("MOD", foreground="#10B981")
        self.term_text.tag_config("IGG", foreground="#F59E0B")
        self.term_text.tag_config("WARN", foreground="#EF4444")
        self.term_text.tag_config("HOOK", foreground="#8B5CF6")

    def log_message(self, tag, message):
        timestamp = time.strftime("%H:%M:%S")
        self.term_text.insert(tk.END, f"[{timestamp}] ", "SYSTEM")
        self.term_text.insert(tk.END, f"[{tag}] ", tag)
        self.term_text.insert(tk.END, f"{message}\n")
        self.term_text.see(tk.END)

    # =========================================================================
    # 4. MOD MENU WINDOW (Complete 14 Switches with D79oM Look)
    # =========================================================================
    def setup_mod_menu_window(self):
        self.menu_frame = tk.Frame(self, bg="#141721", bd=2, relief=tk.RAISED, highlightbackground="#374151", highlightthickness=1)
        self.menu_frame.place(x=680, y=60, width=380, height=540)
        
        # Header Bar with drag support
        header_bar = tk.Frame(self.menu_frame, bg="#1E2333", height=38)
        header_bar.pack(fill=tk.X)
        header_bar.bind("<Button-1>", self.on_menu_drag_start)
        header_bar.bind("<B1-Motion>", self.on_menu_drag_motion)
        
        # Title
        lbl_menu_title = tk.Label(
            header_bar, text="ROS ikhozzzz v2.6.0 VIP", bg="#1E2333", fg="#FFFFFF", font=("Arial", 11, "bold")
        )
        lbl_menu_title.pack(side=tk.LEFT, padx=12, pady=6)
        lbl_menu_title.bind("<Button-1>", self.on_menu_drag_start)
        lbl_menu_title.bind("<B1-Motion>", self.on_menu_drag_motion)

        # Close Button
        btn_close = tk.Button(
            header_bar, text="✕", bg="#EF4444", fg="#FFFFFF", font=("Arial", 10, "bold"),
            bd=0, padx=8, pady=2, activebackground="#DC2626", activeforeground="#FFFFFF",
            command=self.toggle_menu_visibility
        )
        btn_close.pack(side=tk.RIGHT, padx=8, pady=4)

        # Banner image if available
        self.load_menu_banner()

        # Telegram / Credit Subtitle
        sub_bar = tk.Frame(self.menu_frame, bg="#191D2B", pady=4)
        sub_bar.pack(fill=tk.X)
        tk.Label(sub_bar, text="Telegram: @ikhozzzz | Yes 360 + ESP + Fly", bg="#191D2B", fg="#60A5FA", font=("Arial", 9, "bold")).pack()

        # Scrollable Feature List Container
        scroll_container = tk.Frame(self.menu_frame, bg="#141721")
        scroll_container.pack(fill=tk.BOTH, expand=True, padx=6, pady=6)
        
        canvas_list = tk.Canvas(scroll_container, bg="#141721", highlightthickness=0)
        scrollbar = tk.Scrollbar(scroll_container, orient="vertical", command=canvas_list.yview)
        self.feature_inner_frame = tk.Frame(canvas_list, bg="#141721")
        
        self.feature_inner_frame.bind(
            "<Configure>", lambda e: canvas_list.configure(scrollregion=canvas_list.bbox("all"))
        )
        canvas_list.create_window((0, 0), window=self.feature_inner_frame, anchor="nw", width=345)
        canvas_list.configure(yscrollcommand=scrollbar.set)
        
        canvas_list.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        
        # Populate all 14 rows
        self.populate_feature_switches()

    def load_menu_banner(self):
        if os.path.exists(HEADER_IMG_PATH):
            try:
                raw_img = tk.PhotoImage(file=HEADER_IMG_PATH)
                # Subsample to fit banner width (~370px)
                # header.png is 350x350, subsample(2, 4) gives ~175x87
                self.banner_img = raw_img.subsample(2, 4)
                banner_lbl = tk.Label(self.menu_frame, image=self.banner_img, bg="#141721")
                banner_lbl.pack(fill=tk.X, pady=2)
                return
            except Exception as e:
                pass
        
        # Fallback stylish cyber banner
        banner_lbl = tk.Label(
            self.menu_frame, text="⚡ IKHOZZZZ VIP MOD MENU ⚡", bg="#0D1117", fg="#00FFCC",
            font=("Impact", 13), pady=8
        )
        banner_lbl.pack(fill=tk.X)

    def populate_feature_switches(self):
        feature_list = [
            ("WALLHACK", "See players through walls & terrain", "WALLHACK"),
            ("NO RECOIL 100%", "Zero weapon kickback & shake", "NO RECOIL 100%"),
            ("AIMLOCK 100%", "IGG Auto Scan (800,10,1,2 -> 99999)", "AIMLOCK 100%"),
            ("NO RECOIL", "Standard weapon stability patch", "NO RECOIL"),
            ("SPEED", "Player movement velocity 2.5x", "SPEED"),
            ("SPEED EPIC", "Extreme flash movement velocity 5.0x", "SPEED EPIC"),
            ("1 HIT", "Maximum projectile penetration & damage", "1 HIT"),
            ("HIGH SCOPE", "Super 8x camera distance & magnification", "HIGH SCOPE"),
            ("FASH SHOOT", "Rapid automatic fire rate burst", "FASH SHOOT"),
            ("AUTO SCOPE", "Instant zoom lock on aim trigger", "AUTO SCOPE"),
            ("AIMBOT 360", "Camera 360° omnidirectional lock", "AIMBOT 360"),
            ("AIMBOT 180", "180° frontal sweep auto-aim", "AIMBOT 180"),
            ("ESP LINE", "Antenna Sky Beams to all enemies", "ESP LINE"),
            ("FLY", "Zero-gravity sky walker flight mode", "FLY"),
            ("BOT MATCH TEST", "Offline Solo AI Practice (No Server)", "BOT MATCH TEST"),
        ]

        for i, (name, desc, key) in enumerate(feature_list):
            row_bg = "#1A1E2B" if i % 2 == 0 else "#151824"
            row_frame = tk.Frame(self.feature_inner_frame, bg=row_bg, padx=8, pady=5)
            row_frame.pack(fill=tk.X, pady=2)
            
            # Text column
            text_frame = tk.Frame(row_frame, bg=row_bg)
            text_frame.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
            
            # Badge icon / indicator
            prefix = "⭐ " if "360" in key or "ESP" in key or "FLY" in key or "BOT" in key else "• "
            lbl_name = tk.Label(
                text_frame, text=f"{prefix}{name}", bg=row_bg, fg="#FFFFFF" if "360" not in key else "#00FFCC",
                font=("Arial", 10, "bold"), anchor="w"
            )
            lbl_name.pack(anchor="w")
            
            lbl_desc = tk.Label(
                text_frame, text=desc, bg=row_bg, fg="#717D96",
                font=("Arial", 8), anchor="w"
            )
            lbl_desc.pack(anchor="w")
            
            # iOS Switch
            initial_val = self.features[key]
            switch = ModernSwitch(
                row_frame, width=44, height=22, initial=initial_val,
                command=lambda val, k=key: self.on_feature_toggled(k, val),
                bg=row_bg
            )
            switch.pack(side=tk.RIGHT, padx=4)

    def on_feature_toggled(self, key, state):
        self.features[key] = state
        status_str = "ENABLED" if state else "DISABLED"
        
        # Log to debug console
        if key == "AIMLOCK 100%":
            if state:
                self.log_message("IGG", "Scanning memory block (double 999999999, 800, 30)...")
                self.after(300, lambda: self.log_message("IGG", "Found 4 candidate pointer regions"))
                self.after(600, lambda: self.log_message("IGG", "Patched [800, 10, 1, 2] -> 99999.0"))
                self.after(900, lambda: self.log_message("IGG", "Patched [30, 0.1] -> -1.0 [SUCCESS]"))
            else:
                self.log_message("IGG", "Restored default Aimlock memory values")
        elif key == "AIMBOT 360":
            if state:
                self.log_message("HOOK", "sub_1001B05C0 camera yaw constraint hooked")
                self.log_message("HOOK", "MaxAngle: 360.0f (Full Omni-directional active)")
            else:
                self.log_message("HOOK", "Camera angle constraint restored to 120.0f")
        elif key == "ESP LINE":
            if state:
                self.log_message("MOD", f"ESP Sky Antenna vectors active for {len(self.targets)} targets")
            else:
                self.log_message("MOD", "ESP Antenna lines disabled")
        elif key == "FLY":
            if state:
                self.log_message("MOD", "Physics zero-gravity flight enabled (Altitude: +30m)")
                self.altitude = -45.0
            else:
                self.log_message("MOD", "Physics gravity restored to 9.8m/s²")
                self.altitude = 0.0
        elif key == "BOT MATCH TEST":
            if state:
                self.log_message("MOD", "Offline Mode ACTIVE: Bypassed RosLegacy login server")
                self.log_message("MOD", "AI Bot Practice Environment Loaded: 49 Bots spawned")
                self.real_players = 1
                self.bot_players = 49
                self.total_players = 50
                self.update_counter_labels()
            else:
                self.log_message("MOD", "Bot match mode toggled off")
        elif key == "HIGH SCOPE":
            if state:
                self.log_message("MOD", "Camera FOV set to 8x Sniper zoom")
            else:
                self.log_message("MOD", "Camera FOV restored to standard")
        else:
            self.log_message("MOD", f"Feature [{key}] -> {status_str}")

        self.redraw_game_world()

    def on_menu_drag_start(self, event):
        self._menu_drag_x = event.x
        self._menu_drag_y = event.y

    def on_menu_drag_motion(self, event):
        x = self.menu_frame.winfo_x() - self._menu_drag_x + event.x
        y = self.menu_frame.winfo_y() - self._menu_drag_y + event.y
        self.menu_frame.place(x=x, y=y)

    def toggle_menu_visibility(self):
        if self.menu_frame.winfo_viewable():
            self.menu_frame.place_forget()
            self.log_message("UI", "Mod Menu collapsed to floating icon")
        else:
            self.menu_frame.place(x=680, y=60, width=380, height=540)
            self.log_message("UI", "Mod Menu opened")

    # =========================================================================
    # 5. FLOATING MOD MENU ICON (Draggable iOS Floating Bubble)
    # =========================================================================
    def setup_floating_icon(self):
        self.float_icon = tk.Label(self, bg="#0E131D", bd=0, cursor="hand2")
        self.float_icon.place(x=30, y=20)
        
        if os.path.exists(BACK_IMG_PATH):
            try:
                raw_back = tk.PhotoImage(file=BACK_IMG_PATH)
                # Subsample 400x400 down to ~50x50 (8, 8)
                self.icon_img = raw_back.subsample(8, 8)
                self.float_icon.config(image=self.icon_img)
            except Exception:
                self.create_default_float_icon()
        else:
            self.create_default_float_icon()

        self.float_icon.bind("<Button-1>", self.on_icon_click)
        self.float_icon.bind("<B1-Motion>", self.on_icon_drag)

    def create_default_float_icon(self):
        self.float_icon.config(
            text="👑\nROS", bg="#FF3B30", fg="#FFFFFF", font=("Arial", 9, "bold"),
            relief=tk.RAISED, bd=2, padx=6, pady=4
        )

    def on_icon_click(self, event):
        self._icon_drag_x = event.x
        self._icon_drag_y = event.y
        self.toggle_menu_visibility()

    def on_icon_drag(self, event):
        x = self.float_icon.winfo_x() - self._icon_drag_x + event.x
        y = self.float_icon.winfo_y() - self._icon_drag_y + event.y
        self.float_icon.place(x=x, y=y)

    # =========================================================================
    # 6. TICK LOOPS & MATCH SIMULATION
    # =========================================================================
    def game_loop(self):
        # Slightly wander target bots to make preview live and dynamic
        for t in self.targets:
            if t["is_bot"]:
                t["x"] += random.choice([-1, 0, 1])
                t["y"] += random.choice([-1, 0, 1])
                t["x"] = max(100, min(t["x"], self.canvas.winfo_width() - 100))
        
        # Redraw
        self.redraw_game_world()
        self.after(80, self.game_loop)

    def simulate_match_changes(self):
        """Simulate real players eliminating bots in-game"""
        if self.bot_players > 2 and random.random() < 0.4:
            self.bot_players -= 1
            self.total_players = self.real_players + self.bot_players
            self.update_counter_labels()
            self.log_message("KILL", f"Player eliminated a bot! Remaining: {self.total_players}")
        elif self.real_players > 1 and random.random() < 0.15:
            self.real_players -= 1
            self.total_players = self.real_players + self.bot_players
            self.update_counter_labels()
            self.log_message("KILL", f"Real player eliminated! Remaining: {self.total_players}")
        
        self.after(4000, self.simulate_match_changes)


if __name__ == "__main__":
    app = GameScreenPreview()
    app.mainloop()
