<?php

namespace Database\Seeders;

use App\Models\User;
use Illuminate\Database\Console\Seeds\WithoutModelEvents;
use Illuminate\Database\Seeder;
use Illuminate\Support\Facades\DB;

class DatabaseSeeder extends Seeder
{
    use WithoutModelEvents;

    /**
     * Seed the application's database.
     */
    public function run(): void
    {
        $this->call(ChartOfAccountSeeder::class);
        $this->call(CustomerGroupSeeder::class);

        $branchId = DB::table('branches')->insertGetId([
            'code' => 'PUSAT',
            'name' => 'Sumber Makmur Jaya Pusat',
            'created_at' => now(),
            'updated_at' => now(),
        ]);

        foreach (range(1, 5) as $number) {
            $childBranchId = DB::table('branches')->insertGetId([
                'parent_id' => $branchId,
                'code' => 'SMJ-'.$number,
                'name' => 'Sumber Makmur Jaya '.$number,
                'created_at' => now(),
                'updated_at' => now(),
            ]);

            User::factory()->create([
                'branch_id' => $childBranchId,
                'name' => 'Admin SMJ '.$number,
                'email' => 'admin'.$number.'@sumbermakmurjaya.store',
                'password' => 'password',
                'role' => 'manager',
            ]);
        }

        User::factory()->create([
            'branch_id' => $branchId,
            'name' => 'Admin Pusat',
            'email' => 'admin@sumbermakmurjaya.store',
            'role' => 'admin',
        ]);

        $this->call(BranchAccessSeeder::class);
        $this->call(ProductSeeder::class);
    }
}
