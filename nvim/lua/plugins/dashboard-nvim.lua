return {
  "nvimdev/dashboard-nvim",
  opts = function()
    local selectedArt = {
      [[
                  ▄▄██████████▄▄                
                 ▀▀▀   ██   ▀▀▀                 
         ▄██▄   ▄▄████████████▄▄   ▄██▄         
       ▄███▀  ▄████▀▀▀    ▀▀▀████▄  ▀███▄       
      ████▄ ▄███▀              ▀███▄ ▄████      
     ███▀█████▀▄████▄      ▄████▄▀█████▀███     
     ██▀  ███▀ ██████      ██████ ▀███  ▀██     
      ▀  ▄██▀  ▀████▀  ▄▄  ▀████▀  ▀██▄  ▀      
         ███           ▀▀           ███         
         ██████████████████████████████         
     ▄█  ▀██  ███   ██    ██   ███  ██▀  █▄     
     ███  ███ ███   ██    ██   ███▄███  ███     
     ▀██▄████████   ██    ██   ████████▄██▀     
      ▀███▀ ▀████   ██    ██   ████▀ ▀███▀      
       ▀███▄  ▀███████    ███████▀  ▄███▀       
         ▀███    ▀▀██████████▀▀▀   ███▀         
           ▀    ▄▄▄    ██    ▄▄▄    ▀           
                 ▀████████████▀                 
  ]],
      [[
            ▄▄▄▄▄███████████████████▄▄▄▄▄        
          ▄██████████▀▀▀▀▀▀▀▀▀▀██████▀████▄      
         █▀████████▄             ▀▀████ ▀██▄     
        █▄▄██████████████████▄▄▄         ▄██▀    
         ▀█████████████████████████▄    ▄██▀     
           ▀████▀▀▀▀▀▀▀▀▀▀▀▀█████████▄▄██▀       
             ▀███▄              ▀██████▀         
               ▀██████▄        ▄████▀            
                  ▀█████▄▄▄▄▄▄▄███▀              
                    ▀████▀▀▀████▀                
                      ▀███▄███▀                  
                         ▀█▀                     
  ]],
      [[
             ███╗   ███╗ █████╗ ██╗  ██╗███████╗       
             ████╗ ████║██╔══██╗██║ ██╔╝██╔════╝       
             ██╔████╔██║███████║█████╔╝ █████╗         
             ██║╚██╔╝██║██╔══██║██╔═██╗ ██╔══╝         
             ██║ ╚═╝ ██║██║  ██║██║  ██╗███████╗       
             ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝       
               ██████╗ ██████╗  ██████╗ ██╗            
              ██╔════╝██╔═══██╗██╔═══██╗██║            
              ██║     ██║   ██║██║   ██║██║            
              ██║     ██║   ██║██║   ██║██║            
              ╚██████╗╚██████╔╝╚██████╔╝███████╗       
               ╚═════╝ ╚═════╝  ╚═════╝ ╚══════╝       
         ███████╗████████╗██╗   ██╗███████╗███████╗    
         ██╔════╝╚══██╔══╝██║   ██║██╔════╝██╔════╝    
         ███████╗   ██║   ██║   ██║█████╗  █████╗      
         ╚════██║   ██║   ██║   ██║██╔══╝  ██╔══╝      
         ███████║   ██║   ╚██████╔╝██║     ██║         
         ╚══════╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝         
  ]],
      [[
███████╗████████╗██╗███████╗███╗   ███╗██╗███████╗███████╗████████╗███████╗██████╗ 
██╔════╝╚══██╔══╝██║██╔════╝████╗ ████║██║██╔════╝██╔════╝╚══██╔══╝██╔════╝██╔══██╗
███████╗   ██║   ██║█████╗  ██╔████╔██║██║█████╗  ███████╗   ██║   █████╗  ██████╔╝
╚════██║   ██║   ██║██╔══╝  ██║╚██╔╝██║██║██╔══╝  ╚════██║   ██║   ██╔══╝  ██╔══██╗
███████║   ██║   ██║██║     ██║ ╚═╝ ██║██║███████╗███████║   ██║   ███████╗██║  ██║
╚══════╝   ╚═╝   ╚═╝╚═╝     ╚═╝     ╚═╝╚═╝╚══════╝╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝
]],
      [[
                                                 _..--------.._                 
       ________________________              _.-~        ||    ~-._             
     /'                    \ ||`\         /'    \\  |      |  |   ^\            
    |:    ===               -||:  )      /'   \   _.--~~~~--._     / ^\         
     \.____________________/_||../     /'  \    /~            ~\ /  /  ^\       
        |       |                     ||    \ /'     \||  |/    ^\       \      
        |    || ^\     ___-----------/~\  \  /    \           /   \  /    \     
         \    \\  \.-~~   \  |  /   /|  | - |   \   .-~~~~-.    /  \     - ;    
         |           \  \     |  _/' |O |  |~\ __./'        ^\   _  | - _  |    
         |O    /____________..--~ [] |__|- | [] ..   .---._   |  -  | _   _|    
         |   ===____________ --|]=====__|  | [] ..  ( D>   )  |  _  |  _  =|    
         |O    \  /    /    ~~--. [] |  | -| []__    ---'~    |  _  |  -  ~|    
         |           /   /    |  ^\  |O |  |_/   ^\          /      | -    |    
         /    //  .-.__   / |   \  ^\|  | _ |   /  -.____.-'   \  /    \  ;     
        |    ||  /     ~~~------------\_/     \   /            \   /      /     
       _|_______|______________       || /    \      /|  | |\    /  \    /      
     /'                    \ ||`\     \   / / ^\_             /'  \    /        
    |:   ===                -||:  )     ^\        ~-__    __.-~ \  \  /'        
     \.____________________/_||../        ^\  /   /   ~~~~ |        /'          
                                            -._     |  ||    \ _.-'             
                                                ~-..________..-~                
          ]],
      [[
                             __    _                                   
                        _wr""        "-q__                             
                     _dP                 9m_                           
                   _#P                     9#_                         
                  d#@                       9#m                        
                 d##                         ###                       
                J###                         ###L                      
                {###K                       J###K                      
                ]####K      ___aaa___      J####F                      
            __gmM######_  w#P""   ""9#m  _d#####Mmw__                  
         _g##############mZ_         __g##############m_               
       _d####M@PPPP@@M#######Mmp gm#########@@PPP9@M####m_             
      a###""          ,Z"#####@" '######"\g          ""M##m            
     J#@"             0L  "*##     ##@"  J#              *#K           
     #"               `#    "_gmwgm_~    dF               `#_          
    7F                 "#_   ]#####F   _dK                 JE          
    ]                    *m__ ##### __g@"                   F          
                           "PJ#####LP"                                 
     `                       0######_                      '           
                           _0########_                                 
         .               _d#####^#####m__              ,               
          "*w_________am#####P"   ~9#####mw_________w*"                
              ""9@#####@M""           ""P@#####@M                      
      ]],
    }
    math.randomseed(os.time())
    local logo = string.rep("\n", 5) .. selectedArt[math.random(#selectedArt)] .. "\n\n"

    local opts = {
      theme = "doom",
      hide = {
        -- this is taken care of by lualine
        -- enabling this messes up the actual laststatus setting after loading a file
        statusline = false,
      },
      config = {
        header = vim.split(logo, "\n"),
      -- stylua: ignore
      center = {
        { action = 'lua LazyVim.pick()()',                           desc = " Find File",       icon = " ", key = "f" },
        { action = "ene | startinsert",                              desc = " New File",        icon = " ", key = "n" },
        { action = 'lua LazyVim.pick("oldfiles")()',                 desc = " Recent Files",    icon = " ", key = "r" },
        { action = 'lua LazyVim.pick("live_grep")()',                desc = " Find Text",       icon = " ", key = "g" },
        { action = 'lua LazyVim.pick.config_files()()',              desc = " Config",          icon = " ", key = "c" },
        { action = 'lua require("persistence").load()',              desc = " Restore Session", icon = " ", key = "s" },
        { action = "LazyExtras",                                     desc = " Lazy Extras",     icon = " ", key = "x" },
        { action = "Lazy",                                           desc = " Lazy",            icon = "󰒲 ", key = "l" },
        { action = function() vim.api.nvim_input("<cmd>qa<cr>") end, desc = " Quit",            icon = " ", key = "q" },
      },
        footer = function()
          local stats = require("lazy").stats()
          local ms = (math.floor(stats.startuptime * 100 + 0.5) / 100)
          return { "⚡ Neovim loaded " .. stats.loaded .. "/" .. stats.count .. " plugins in " .. ms .. "ms" }
        end,
      },
    }

    for _, button in ipairs(opts.config.center) do
      button.desc = button.desc .. string.rep(" ", 43 - #button.desc)
      button.key_format = "  %s"
    end

    -- open dashboard after closing lazy
    if vim.o.filetype == "lazy" then
      vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(vim.api.nvim_get_current_win()),
        once = true,
        callback = function()
          vim.schedule(function()
            vim.api.nvim_exec_autocmds("UIEnter", { group = "dashboard" })
          end)
        end,
      })
    end

    return opts
  end,
}