//
//  main.swift
//  PolarisMCP
//
//  The helper Claude launches. It holds no credentials and makes no network
//  call: it reads the snapshot Polaris last wrote and answers from that, so
//  there is only ever one client signed in to Polestar.
//

import PolarisMCPKit

MCPServer().run()
